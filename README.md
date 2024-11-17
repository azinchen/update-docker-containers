# update-docker-containers

This script updates Docker Compose and standalone Docker containers. It pulls the latest images, recreates containers if necessary, and cleans up unused Docker resources.

## Installation

1. **Place the script in `/usr/local/bin` or a similar directory:**

   ```sh
   sudo cp update-docker-containers.sh /usr/local/bin/update-docker-containers
   sudo chmod +x /usr/local/bin/update-docker-containers
   ```

2. **Create a cron task to run the script periodically:**

   Open the crontab file for editing:

   ```sh
   crontab -e
   ```

   Add the following line to run the script daily at midnight (adjust the schedule as needed):

   ```sh
   0 0 * * * /usr/local/bin/update-docker-containers /path/to/base_directory >> /var/log/docker-update/docker-update.log 2>> /var/log/docker-update/docker-update-error.log
   ```

   Ensure that `/path/to/base_directory` is replaced with the actual path to your parent directory containing the Docker Compose project subdirectories.

3. **Set up log rotation:**

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
       sharedscripts
       postrotate
           /usr/bin/killall -HUP rsyslogd
       endscript
   }
   ```

   This configuration rotates the logs daily, keeps 14 days of logs, compresses old logs, and ensures the logs are created with the correct permissions.

## Usage

Run the script manually:

```sh
update-docker-containers /path/to/base_directory
```

Replace `/path/to/base_directory` with the path to the parent directory that contains subdirectories, each housing a `docker-compose.yml` file.

### Example

```plaintext
/home/user/docker_projects/
├── project1/
│   └── docker-compose.yml
├── project2/
│   └── docker-compose.yml
└── project3/
    └── docker-compose.yml
```

You would replace `/path/to/base_directory` with `/home/user/docker_projects` when running the script:

```sh
update_docker_containers /home/user/docker_projects
```

Explanation:

* **Base Directory**: This is the main directory that contains all your Docker Compose project subdirectories.
* **Subdirectories**: Each subdirectory within the base directory should contain its own docker-compose.yml file.

This structure allows the script to automatically locate and process each Docker Compose project within the specified base directory.

## Logs

- Informational logs: `/var/log/docker-update/docker-update.log`
- Error logs: `/var/log/docker-update/docker-update-error.log`

Ensure the log directory exists and has the correct permissions:

```sh
sudo mkdir -p /var/log/docker-update
sudo touch /var/log/docker-update/docker-update.log /var/log/docker-update/docker-update-error.log
sudo chown root:root /var/log/docker-update/docker-update.log /var/log/docker-update/docker-update-error.log
sudo chmod 0640 /var/log/docker-update/docker-update.log /var/log/docker-update/docker-update-error.log
```

## License

This project is licensed under the MIT License.
