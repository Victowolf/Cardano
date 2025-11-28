FROM ubuntu:22.04


# Minimal dependencies. You may want to use a base image that already bundles cardano-node/cli.
RUN apt-get update && apt-get install -y --no-install-recommends \
ca-certificates curl jq gnupg unzip socat netcat iputils-ping \
libpq-dev build-essential autoconf automake libtool pkg-config git python3 python3-pip \
&& rm -rf /var/lib/apt/lists/*


# TODO: Install cardano-node and cardano-cli here, or use a prebuilt image.
# For production, replace the following with your cardano-node install steps or COPY a prebuilt binary.


WORKDIR /opt/cardano


# Copy repo files
COPY . /opt/cardano


# Ensure scripts are executable
RUN chmod +x /opt/cardano/start.sh /opt/cardano/entrypoint.sh /opt/cardano/scripts/*.sh


ENV PATH="/opt/cardano/bin:$PATH"


ENTRYPOINT ["/opt/cardano/entrypoint.sh"]