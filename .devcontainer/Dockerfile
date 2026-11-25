FROM mcr.microsoft.com/devcontainers/dotnet:1-8.0-bookworm

# The base image ships an apt source for yarn whose signing key is missing, which
# makes `apt-get update` fail and in turn breaks every devcontainer feature that
# installs packages (powershell, sshd). yarn is not used here, so drop the source.
RUN rm -f /etc/apt/sources.list.d/yarn.list
