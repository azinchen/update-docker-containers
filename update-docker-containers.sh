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

# Resolve to an absolute path so changing into project directories keeps
# working even when a relative base path is given
BASE_PATH=$(realpath "$BASE_PATH")

echo "=============================================="
echo "Docker Compose and Standalone Containers Update Script Started"
date
echo "=============================================="
echo "Base Path: $BASE_PATH"
echo ""

# --- Processing Docker Compose Projects ---

# Determine the Docker Compose command
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE_COMMAND="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_COMMAND="docker-compose"
else
    echo "Neither 'docker compose' nor 'docker-compose' is available. Skipping Compose projects." >&2
    DOCKER_COMPOSE_COMMAND=""
fi

if [ -n "$DOCKER_COMPOSE_COMMAND" ]; then
    # Find all directories containing a Compose file
    compose_dirs=$(find "$BASE_PATH" -maxdepth 2 -type f \
        \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
        -o -name 'compose.yml' -o -name 'compose.yaml' \) \
        -printf '%h\n' | sort -u)

    if [ -z "$compose_dirs" ]; then
        echo "No Compose files found in '$BASE_PATH'."
    else
        # Loop over all Compose project directories
        echo "Processing Docker Compose projects..."
        echo ""
        while IFS= read -r compose_dir; do

            project_name=$(basename "$compose_dir")

            echo "----------------------------------------------"
            echo "Processing Compose project: $project_name"
            echo "Directory: $compose_dir"
            echo "----------------------------------------------"
            echo ""

            # Change to the project directory so the Compose command picks
            # up the Compose file (and any .env file) automatically
            if ! cd "$compose_dir"; then
                echo "Failed to change directory to '$compose_dir'. Skipping." >&2
                continue
            fi

            # Get the list of services defined in the Compose file
            services=$($DOCKER_COMPOSE_COMMAND config --services) || {
                echo "Failed to get services for project '$project_name'. Skipping." >&2
                continue
            }

            if [ -z "$services" ]; then
                echo "No services found for project '$project_name'. Skipping." >&2
                continue
            fi

            # Initialize flags
            compose_project_has_updates=false
            containers_not_running=false

            # Pull the latest images. '--quiet' suppresses the per-layer
            # progress output; errors still go to stderr.
            echo "Pulling latest images for project '$project_name'..."
            if ! $DOCKER_COMPOSE_COMMAND pull --quiet; then
                echo "Failed to pull images for project '$project_name'. Skipping." >&2
                continue
            fi
            echo "Image pull completed for project '$project_name'."
            echo ""

            # Loop over each service
            for service in $services; do
                # Get the container ID for the service (first one if the
                # service is scaled). Asking Compose avoids guessing the
                # project name, which may be normalized or overridden.
                container_id=$($DOCKER_COMPOSE_COMMAND ps -q "$service" | head -n 1)

                # If the container does not exist or is not running
                if [ -z "$container_id" ] \
                    || [ "$(docker inspect --format '{{.State.Running}}' \
                        "$container_id" 2> /dev/null)" != "true" ]; then
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

                # Get the image ID the container is currently running
                if ! image_id_before=$(docker inspect \
                    --format '{{.Image}}' "$container_id"); then
                    echo "Failed to get image ID for container '$container_id'. Skipping service '$service'." >&2
                    continue
                fi

                # Get the image ID after the pull
                if ! image_id_after=$(docker image inspect \
                    --format '{{.Id}}' "$image_name"); then
                    echo "Failed to get image ID after pull for image '$image_name'. Skipping service '$service'." >&2
                    continue
                fi

                if [ "$image_id_before" != "$image_id_after" ]; then
                    echo "A newer version is available for image '$image_name'."
                    echo "Image ID before pull: $image_id_before"
                    echo "Image ID after pull:  $image_id_after"
                    compose_project_has_updates=true
                    echo "Skipping further checks for project '$project_name'."
                    break
                else
                    echo "Image '$image_name' is up-to-date."
                fi

                echo ""

            done

            # Recreate services if needed. '--force-recreate' rebuilds
            # every container in the project in dependency order, so
            # services that inherit another service's network namespace
            # (network_mode: service:...) are re-attached to the new
            # container instead of being left on a dead namespace.
            if [ "$compose_project_has_updates" = true ] \
                || [ "$containers_not_running" = true ]; then
                echo "Updating services for project '$project_name'..."
                echo ""

                if ! $DOCKER_COMPOSE_COMMAND up --detach --force-recreate \
                    --quiet-pull; then
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

        done <<< "$compose_dirs"
    fi
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
        # Get the container name (strip the leading '/')
        if ! container_name=$(docker inspect \
            --format '{{.Name}}' "$container_id"); then
            echo "Failed to get name for container '$container_id'. Skipping." >&2
            continue
        fi
        container_name=${container_name#/}

        # Get the image name used by the container
        if ! image_name=$(docker inspect \
            --format '{{.Config.Image}}' "$container_id"); then
            echo "Failed to get image name for container '$container_id'. Skipping." >&2
            continue
        fi

        echo "Checking standalone container: $container_name"
        echo "Image: $image_name"

        # Pull the latest image. '--quiet' suppresses the per-layer
        # progress output; errors still go to stderr.
        echo "Pulling latest image for '$image_name'..."
        if ! docker pull --quiet "$image_name"; then
            echo "Failed to pull image '$image_name'. Skipping container '$container_name'." >&2
            continue
        fi
        echo "Image pull completed for '$image_name'."

        # Get the image ID the container is currently running
        if ! image_id_before=$(docker inspect \
            --format '{{.Image}}' "$container_id"); then
            echo "Failed to get image ID for container '$container_id'. Skipping." >&2
            continue
        fi

        # Get the image ID after the pull
        if ! image_id_after=$(docker image inspect \
            --format '{{.Id}}' "$image_name"); then
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

            # Extract run options from the old container's configuration.
            # Each jq filter emits one command-line token per line, and
            # readarray keeps every token (including ones containing
            # spaces) as a single argument.
            #
            # NOTE: only a subset of the configuration is preserved:
            # command, environment variables, port bindings, volumes,
            # network mode, restart policy and extra hosts. Settings such
            # as entrypoint overrides, labels, resource limits,
            # capabilities, devices and healthchecks are not carried over.

            # Command
            readarray -t cmd_args < <(echo "$config_json" | jq -r \
                '.[0].Config.Cmd // [] | .[]')

            # Environment Variables
            readarray -t env_args < <(echo "$config_json" | jq -r \
                '.[0].Config.Env // [] | .[] | "-e", .')

            # Port Bindings (keeps host IP and protocol, and all host
            # bindings of a container port)
            readarray -t port_args < <(echo "$config_json" | jq -r \
                '.[0].HostConfig.PortBindings // {} | to_entries[]? |
                .key as $container_port | .value[]? |
                "-p",
                ((if (.HostIp // "") != "" then "\(.HostIp):" else "" end)
                    + "\(.HostPort):\($container_port)")')

            # Volume and Bind Mounts (named volumes are remounted by
            # volume name, bind mounts by source path)
            readarray -t volume_args < <(echo "$config_json" | jq -r \
                '.[0].Mounts // [] | .[] |
                "-v",
                "\(if .Type == "volume" then .Name else .Source end):\(.Destination)\(if .RW == false then ":ro" else "" end)"')

            # Network Mode
            readarray -t network_args < <(echo "$config_json" | jq -r \
                '.[0].HostConfig.NetworkMode // "" |
                select(length > 0) |
                "--network", .')

            # Restart Policy
            readarray -t restart_args < <(echo "$config_json" | jq -r \
                '.[0].HostConfig.RestartPolicy.Name // "" |
                select(length > 0) |
                "--restart", .')

            # Extra Hosts
            readarray -t extra_host_args < <(echo "$config_json" | jq -r \
                '.[0].HostConfig.ExtraHosts // [] | .[] |
                "--add-host", .')

            # Build the docker run command as an array; empty option
            # arrays expand to nothing
            docker_run_cmd=(docker run --detach --name "$container_name"
                "${restart_args[@]}"
                "${network_args[@]}"
                "${port_args[@]}"
                "${volume_args[@]}"
                "${env_args[@]}"
                "${extra_host_args[@]}"
                "$image_name"
                "${cmd_args[@]}")

            # Stop the old container and rename it out of the way so the
            # replacement can take the original name. It is only removed
            # after the new container starts, so a failed recreate can be
            # rolled back instead of losing the container.
            backup_name="${container_name}-old"

            if ! docker stop "$container_id"; then
                echo "Failed to stop container '$container_name'. Skipping." >&2
                continue
            fi

            if ! docker rename "$container_id" "$backup_name"; then
                echo "Failed to rename container '$container_name' to '$backup_name' (a leftover container may already use that name). Restarting the existing container." >&2
                if ! docker start "$container_id"; then
                    echo "Failed to restart container '$container_name'." >&2
                fi
                continue
            fi

            # Print the command for debugging
            echo "Running command: ${docker_run_cmd[*]}"

            # Run the replacement; on failure restore the old container
            if ! "${docker_run_cmd[@]}"; then
                echo "Failed to recreate container '$container_name'. Restoring the previous container." >&2

                # Remove a partially created replacement, if any, so the
                # original name is free again
                docker rm --force "$container_name" &> /dev/null || true

                if ! docker rename "$container_id" "$container_name" \
                    || ! docker start "$container_id"; then
                    echo "Failed to restore container '$container_name'; it is stopped and named '$backup_name'." >&2
                fi
                continue
            fi

            # The replacement is running; remove the old container
            if ! docker rm "$container_id"; then
                echo "Failed to remove the old container '$backup_name'. Remove it manually." >&2
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

echo "Cleaning up unused Docker images..."
echo ""

# Remove images not used by any container (old image versions left behind
# by updates). Containers, volumes and networks are intentionally left
# untouched. Output is captured instead of piped so a filter failure
# cannot mask the prune exit status.
if ! prune_output=$(docker image prune --all --force); then
    echo "Failed to prune unused Docker images." >&2
    exit 1
fi

# Print the prune report without the per-layer 'deleted: sha256:...'
# noise, keeping the removed image references ('untagged: ...') and the
# total reclaimed space
grep -v '^deleted: sha256:' <<< "$prune_output"

echo "Docker cleanup completed."
echo ""
echo "Script execution completed."
date
echo "=============================================="
