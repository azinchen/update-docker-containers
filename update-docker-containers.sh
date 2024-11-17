#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Check if required commands are available
for cmd in docker jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Command '$cmd' not found. Please install it before running this script." >&2
        exit 1
    fi
done

# Check if a base path was provided as an input parameter
if [ -z "$1" ]; then
    echo "Usage: $0 <base_path>" >&2
    exit 1
fi

# Set the base path from the input parameter
BASE_PATH="$1"

# Check if the base path exists and is a directory
if [ ! -d "$BASE_PATH" ]; then
    echo "The base path '$BASE_PATH' does not exist or is not a directory." >&2
    exit 1
fi

# Function to get the project name from a Compose file
get_project_name() {
    local compose_file="$1"
    if [ -z "$compose_file" ]; then
        echo "Compose file path is empty." >&2
        exit 1
    fi
    # Default project name is the directory name
    local project_name
    project_name=$(basename "$(dirname "$compose_file")")
    echo "$project_name"
}

echo "=============================================="
echo "Docker Compose and Standalone Containers Update Script Started"
echo "=============================================="
echo "Base Path: $BASE_PATH"
echo ""

# --- Processing Docker Compose Projects ---

# Determine the Docker Compose command
if command -v docker &> /dev/null \
    && docker compose version &> /dev/null; then
    DOCKER_COMPOSE_COMMAND="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_COMMAND="docker-compose"
else
    echo "Neither 'docker compose' nor 'docker-compose' is available. Skipping." >&2
    echo ""
    continue
fi

# Find all docker-compose.yml files
compose_files=$(find "$BASE_PATH" -maxdepth 2 -type f -name "docker-compose.yml" | sort)

if [ -z "$compose_files" ]; then
    echo "No docker-compose.yml files found in '$BASE_PATH'."
else
    # Loop over all docker-compose.yml files
    echo "Processing Docker Compose projects..."
    echo ""
    while IFS= read -r compose_file; do

        echo "----------------------------------------------"
        echo "Processing Compose file: $compose_file"
        echo "----------------------------------------------"
        echo ""

        # Get the project name
        project_name=$(get_project_name "$compose_file")
        if [ -z "$project_name" ]; then
            echo "Could not determine project name for '$compose_file'. Skipping." >&2
            continue
        fi

        # Change to the directory containing the docker-compose.yml file
        compose_dir=$(dirname "$compose_file")
        if ! cd "$compose_dir"; then
            echo "Failed to change directory to '$compose_dir'. Skipping." >&2
            continue
        fi

        # Get the list of services defined in the compose file
        services=$($DOCKER_COMPOSE_COMMAND config --services) || {
            echo "Failed to get services from compose file '$compose_file'. Skipping." >&2
            continue
        }

        if [ -z "$services" ]; then
            echo "No services found in compose file '$compose_file'. Skipping." >&2
            continue
        fi

        # Initialize flags
        compose_file_has_updates=false
        containers_not_running=false

        # Pull the latest images
        echo "Pulling latest images for project '$project_name'..."
        if ! $DOCKER_COMPOSE_COMMAND pull; then
            echo "Failed to pull images for project '$project_name'. Skipping." >&2
            continue
        fi
        echo "Image pull completed for project '$project_name'."
        echo ""

        # Loop over each service
        for service in $services; do
            # Get the container ID (if running)
            container_id=$(docker ps \
                --filter "label=com.docker.compose.project=$project_name" \
                --filter "label=com.docker.compose.service=$service" \
                --format '{{.ID}}')

            # If container is not running
            if [ -z "$container_id" ]; then
                echo "Service '$service' is not running."
                containers_not_running=true
                echo "Skipping further checks for project '$project_name'."
                break
            fi

            # Get the image name used by the container
            if ! image_name=$(docker inspect \
                --format '{{.Config.Image}}' "$container_id"); then
                echo "Failed to get image name for container '$container_id'. Skipping service '$service'." >&2
                continue
            fi

            echo "Checking service: $service"
            echo "Image: $image_name"

            # Get the image ID before the pull
            if ! image_id_before=$(docker inspect \
                --format '{{.Image}}' "$container_id"); then
                echo "Failed to get image ID for container '$container_id'. Skipping service '$service'." >&2
                continue
            fi

            # Get the image ID after the pull
            image_id_after=$(docker images --no-trunc \
                --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
                | grep "^$image_name " \
                | awk '{print $2}')

            if [ -z "$image_id_after" ]; then
                echo "Failed to get image ID after pull for image '$image_name'. Skipping service '$service'." >&2
                continue
            fi

            if [ "$image_id_before" != "$image_id_after" ]; then
                echo "A newer version is available for image '$image_name'."
                echo "Image ID before pull: $image_id_before"
                echo "Image ID after pull:  $image_id_after"
                compose_file_has_updates=true
                echo "Skipping further checks for project '$project_name'."
                break
            else
                echo "Image '$image_name' is up-to-date."
            fi

            echo ""

        done

        # Determine if we need to restart the services
        if [ "$compose_file_has_updates" = true ] \
            || [ "$containers_not_running" = true ]; then
            echo "Updating and restarting services for project '$project_name'..."
            echo ""

            # Bring down and restart the services
            if ! $DOCKER_COMPOSE_COMMAND down; then
                echo "Failed to bring down services for project '$project_name'." >&2
                continue
            fi

            if ! $DOCKER_COMPOSE_COMMAND up --detach; then
                echo "Failed to bring up services for project '$project_name'." >&2
                continue
            fi

            echo "Services in project '$project_name' have been updated."
        else
            echo "All services in project '$project_name' are up-to-date and running."
        fi

        echo ""
        echo "=============================================="
        echo ""

    done <<< "$compose_files"
fi

# --- Processing Standalone Containers ---

echo "----------------------------------------------"
echo "Processing Standalone Docker Containers"
echo "----------------------------------------------"
echo ""

# Get the list of all running containers
all_containers=$(docker ps --format '{{.ID}}') || {
    echo "Failed to get list of running containers." >&2
    exit 1
}

# Get the list of containers managed by Docker Compose
compose_containers=$(docker ps \
    --filter 'label=com.docker.compose.project' \
    --format '{{.ID}}') || {
    echo "Failed to get list of Docker Compose containers." >&2
    exit 1
}

# Get the list of standalone containers
standalone_containers=$(comm -23 \
    <(echo "$all_containers" | sort) \
    <(echo "$compose_containers" | sort))

if [ -z "$standalone_containers" ]; then
    echo "No standalone containers exist to check for updates."
else
    # Initialize flag to track if any standalone containers were updated
    standalone_updates=false

    # Loop over each standalone container
    for container_id in $standalone_containers; do
        # Get the container name
        if ! container_name=$(docker inspect \
            --format '{{.Name}}' "$container_id" \
            | cut --characters=2-); then
            echo "Failed to get name for container '$container_id'. Skipping." >&2
            continue
        fi

        # Get the image name used by the container
        if ! image_name=$(docker inspect \
            --format '{{.Config.Image}}' "$container_id"); then
            echo "Failed to get image name for container '$container_id'. Skipping." >&2
            continue
        fi

        echo "Checking standalone container: $container_name"
        echo "Image: $image_name"

        # Pull the latest image
        echo "Pulling latest image for '$image_name'..."
        if ! docker pull "$image_name"; then
            echo "Failed to pull image '$image_name'. Skipping container '$container_name'." >&2
            continue
        fi
        echo "Image pull completed for '$image_name'."

        # Get the image ID before the pull
        if ! image_id_before=$(docker inspect \
            --format '{{.Image}}' "$container_id"); then
            echo "Failed to get image ID for container '$container_id'. Skipping." >&2
            continue
        fi

        # Get the image ID after the pull
        image_id_after=$(docker images --no-trunc \
            --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
            | grep "^$image_name " \
            | awk '{print $2}')

        if [ -z "$image_id_after" ]; then
            echo "Failed to get image ID after pull for image '$image_name'. Skipping container '$container_name'." >&2
            continue
        fi

        if [ "$image_id_before" != "$image_id_after" ]; then
            echo "A newer version is available for image '$image_name'."
            echo "Image ID before pull: $image_id_before"
            echo "Image ID after pull:  $image_id_after"
            echo "Recreating container '$container_name' with the updated image..."

            # Get the container's configuration
            if ! config_json=$(docker inspect "$container_id"); then
                echo "Failed to inspect container '$container_id'. Skipping." >&2
                continue
            fi

            # Extract necessary configurations

            # Command
            if ! cmd=$(echo "$config_json" | jq -r \
                '.[0].Config.Cmd // [] | @sh'); then
                cmd=""
            fi

            # Environment Variables
            if ! env_vars=$(echo "$config_json" | jq -r \
                '.[0].Config.Env // [] | .[] |
                @sh "-e \(.|gsub("\""; "\\\""))"'); then
                env_vars=""
            fi

            # Port Bindings
            if ! port_bindings=$(echo "$config_json" | jq -r \
                '.[0].HostConfig.PortBindings // {} |
                to_entries[]? |
                "-p \(.value[0].HostPort):\(.key|split("/")[0])"'); then
                port_bindings=""
            fi

            # Volume Bindings
            if ! volume_bindings=$(echo "$config_json" | jq -r \
                '.[0].Mounts // [] | .[] |
                "-v \(.Source):\(.Destination)\(if .RW == false then ":ro" else "" end)"'); then
                volume_bindings=""
            fi

            # Network Mode
            if ! network_mode=$(echo "$config_json" | jq -r \
                '.[0].HostConfig.NetworkMode // "" |
                select(length > 0) |
                "--network \(.)"'); then
                network_mode=""
            fi

            # Restart Policy
            if ! restart_policy=$(echo "$config_json" | jq -r \
                '.[0].HostConfig.RestartPolicy.Name // "" |
                select(length > 0) |
                "--restart \(.)"'); then
                restart_policy=""
            fi

            # Extra Hosts
            if ! extra_hosts=$(echo "$config_json" | jq -r \
                '.[0].HostConfig.ExtraHosts // [] | .[] |
                "--add-host \(.)"'); then
                extra_hosts=""
            fi

            name="--name $container_name"

            # Stop and remove the old container
            if ! docker stop "$container_id"; then
                echo "Failed to stop container '$container_name'. Skipping." >&2
                continue
            fi

            if ! docker rm "$container_id"; then
                echo "Failed to remove container '$container_name'. Skipping." >&2
                continue
            fi

            # Build the docker run command as an array
            docker_run_cmd=(docker run -d "$name")

            # Add options if they are not empty
            [ -n "$restart_policy" ] && docker_run_cmd+=("$restart_policy")
            [ -n "$network_mode" ] && docker_run_cmd+=("$network_mode")

            # Read port_bindings into an array
            readarray -t port_bindings_array <<< "$port_bindings"
            if [ ${#port_bindings_array[@]} -gt 0 ]; then
                docker_run_cmd+=("${port_bindings_array[@]}")
            fi

            # Read volume_bindings into an array
            readarray -t volume_bindings_array <<< "$volume_bindings"
            if [ ${#volume_bindings_array[@]} -gt 0 ]; then
                docker_run_cmd+=("${volume_bindings_array[@]}")
            fi

            # Read env_vars into an array
            readarray -t env_vars_array <<< "$env_vars"
            if [ ${#env_vars_array[@]} -gt 0 ]; then
                docker_run_cmd+=("${env_vars_array[@]}")
            fi

            # Read extra_hosts into an array
            readarray -t extra_hosts_array <<< "$extra_hosts"
            if [ ${#extra_hosts_array[@]} -gt 0 ]; then
                docker_run_cmd+=("${extra_hosts_array[@]}")
            fi

            # Append the image name
            docker_run_cmd+=("$image_name")

            # Append the command, if any
            [ -n "$cmd" ] && docker_run_cmd+=("$cmd")

            # Print the command for debugging
            echo "Running command: ${docker_run_cmd[*]}"

            # Run the container
            if ! "${docker_run_cmd[@]}"; then
                echo "Failed to recreate container '$container_name'." >&2
                continue
            fi

            echo "Container '$container_name' has been updated and restarted."
            standalone_updates=true
        else
            echo "Container '$container_name' is up-to-date."
        fi

        echo ""
    done

    if [ "$standalone_updates" = true ]; then
        echo "Standalone containers have been updated."
    else
        echo "All standalone containers are up-to-date."
    fi
fi

echo ""
echo "=============================================="
echo ""

# --- Clean up unused Docker resources ---

echo "Cleaning up unused Docker resources..."
echo ""

# Perform cleanup with a single command
if ! docker system prune --all --volumes --force; then
    echo "Failed to perform Docker system prune." >&2
    exit 1
fi

echo "Docker cleanup completed."
echo ""
echo "Script execution completed."
echo "=============================================="
