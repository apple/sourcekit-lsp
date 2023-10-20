## Using VSCode devcontainers

VSCode supports creating development environments inside of a docker container. With some light configuration, we can get a consistent development environment that is robust to changes in your local environment and also doesn't require you to install and manage dependencies on your machine.

### Setup

1. Install Docker, a tool for managing containerized VMs: https://www.docker.com
  - If you have Docker installed, make sure it is updated to the most recent version (there is a "Check for Updates" option in the application UI).
  - If installing Docker on macOS for the first time, I recommend selecting the "Advanced" installation option, specifying a "User" installation and disabling the two  options below. This makes it so your Docker installation does not require root privileges for anything, which is generally nice and makes updates more seamless. This will require you telling VSCode where the `docker` executable ended up by changing the "dev.containers.dockerPath" setting (usually to something like `"/Users/<your-user-name>/.docker/bin/docker”`). You should make sure this executable exists by executing `"/<expected-path-to-docker>/docker --version”`.
2. Install Visual Studio Code and the Remote Containers extensions: https://code.visualstudio.com/docs/devcontainers/tutorial
3. Configure Docker by opening up the Docker application and navigating to "Settings"
  - Recommended settings for macOS (some of these are defaults):
    - General:
      - "Choose file sharing implementation for your containers": VirtioFS (better IO performance)
    - Resources:
      - CPUs: Allow docker to use most or all of your CPUs
      - Memory: Allow docker to use most or all of your memory
4. Open up this repository in VSCode
  - VSCode has an "Install 'code' command in PATH" command which installs a helpful tool to open VSCode from the commandline (`code <path-to-this-repo>`)
5. Select "Reopen in Container" in the notification that pops up
  - If there is no popup you can manually open the dev container by selecting "Dev Containers: Rebuild and Reopen in Container" from the command palette (Command-Shift-P on macOS)
  - Occasionally, after pulling from git, VSCode may prompt you to rebuild the container if the container definition has changed
6. Wait for the container to be built
