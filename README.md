# update-docker-containers

This script updates Docker Compose and standalone Docker containers. It pulls the latest images, recreates containers if necessary, and cleans up unused Docker images.

## Requirements

- `bash`
- `docker` with the Compose plugin (`docker compose`) or the standalone `docker-compose` binary
- `jq`

## Installation

1. **Place the script in `/usr/local/bin` or a similar directory:**

   ```sh
   sudo cp update-docker-containers.sh /usr/local/bin/update-docker-containers
   sudo chmod +x /usr/local/bin/update-docker-containers
   ```

2. **Create the log directory:**

   ```sh
   sudo mkdir -p /var/log/docker-update
   sudo touch /var/log/docker-update/docker-update.log /var/log/docker-update/docker-update-error.log
   sudo chown root:root /var/log/docker-update/docker-update.log /var/log/docker-update/docker-update-error.log
   sudo chmod 0640 /var/log/docker-update/docker-update.log /var/log/docker-update/docker-update-error.log
   ```

3. **Create a cron task to run the script periodically:**

   The script needs root privileges (for Docker access and for writing to the log files created above), so add it to root's crontab:

   ```sh
   sudo crontab -e
   ```

   Add the following line to run the script daily at midnight (adjust the schedule as needed):

   ```sh
   0 0 * * * /usr/local/bin/update-docker-containers /path/to/base_directory >> /var/log/docker-update/docker-update.log 2>> /var/log/docker-update/docker-update-error.log
   ```

   Ensure that `/path/to/base_directory` is replaced with the actual path to your parent directory containing the Docker Compose project subdirectories.

4. **Set up log rotation:**

   Create a logrotate configuration file for the script:

   ```sh
   sudo nano /etc/logrotate.d/docker-update
   ```

   Add the following content to the file:

   ```plaintext
   /var/log/docker-update/*.log {
       daily
       missingok
       rotate 14
       compress
       delaycompress
       notifempty
       create 0640 root root
   }
   ```

   This configuration rotates the logs daily, keeps 14 days of logs, compresses old logs, and ensures the logs are created with the correct permissions. No `postrotate` script is needed: the logs are written by cron's output redirection, which reopens the log files on every run.

## Usage

Run the script manually:

```sh
update-docker-containers /path/to/base_directory
```

Replace `/path/to/base_directory` with the path to the parent directory that contains subdirectories, each housing a Compose file (`docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, or `compose.yaml`).

### Example

```plaintext
/home/user/docker_projects/
├── project1/
│   └── docker-compose.yml
├── project2/
│   └── compose.yaml
└── project3/
    └── docker-compose.yml
```

You would replace `/path/to/base_directory` with `/home/user/docker_projects` when running the script:

```sh
update-docker-containers /home/user/docker_projects
```

Explanation:

* **Base Directory**: This is the main directory that contains all your Docker Compose project subdirectories.
* **Subdirectories**: Each subdirectory within the base directory should contain its own Compose file.

This structure allows the script to automatically locate and process each Docker Compose project within the specified base directory.

## How it works

* **Docker Compose projects**: For each project directory, the script pulls the latest images and compares image IDs. If a service uses an outdated image or is not running, it runs `docker compose up --detach`, which recreates only the containers whose image or configuration changed — unchanged services keep running without interruption. Note that services which are intentionally stopped will be started again.
* **Standalone containers**: For each running container not managed by Compose, the script pulls the latest image. If a newer image is available, the container is stopped, removed, and recreated with the new image, preserving its command, environment variables, port bindings, volumes, network mode, restart policy, and extra hosts.

  > **Limitation:** other settings — entrypoint overrides, labels, resource limits, capabilities, devices, healthchecks, etc. — are **not** carried over. For standalone containers with complex configurations, consider a dedicated tool such as [Watchtower](https://containrrr.dev/watchtower/) instead.
* **Cleanup**: After updating, the script runs `docker system prune --all --force`.

  > **Warning:** this removes **all** images not used by at least one container — not just old versions of updated images. Volumes and bind mounts are never touched.

## Logs

- Informational logs: `/var/log/docker-update/docker-update.log`
- Error logs: `/var/log/docker-update/docker-update-error.log`

The log directory and files are set up in step 2 of the Installation section.

## License

This project is licensed under the MIT License.
