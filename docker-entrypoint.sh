#!/bin/bash

if [ "$1" = 'valkey-cluster' ]; then
    shift  # consume the subcommand

    # default IP from env or empty
    IP="${IP:-}"

    # parse args
    while [ $# -gt 0 ]; do
      case "$1" in
        --port)                  [[ -z $INITIAL_PORT ]] && INITIAL_PORT="$2"; shift ;; # only set if not using TLS
        --tls-port)              TLS_ENABLED=true; INITIAL_PORT="$2"; shift ;;
        --tls-cert-file)         TLS_CERT_FILE="$2"; shift ;;
        --tls-key-file)          TLS_KEY_FILE="$2"; shift ;;
        --tls-ca-cert-file)      TLS_CA_CERT_FILE="$2"; shift ;;
        --*) ;;  # ignore other flags
        *)
          # first non‑flag argument is the IP if not already set
          if [ -z "$IP" ]; then IP="$1"; fi
          ;;
      esac
      shift
    done

    if [ -z "$IP" ]; then # If IP is unset then discover it
        IP=$(hostname -I)
    fi

    echo " -- IP Before trim: '$IP'"
    IP=$(echo ${IP}) # trim whitespaces
    echo " -- IP Before split: '$IP'"
    IP=${IP%% *} # use the first ip
    echo " -- IP After trim: '$IP'"

    if [ -z "$INITIAL_PORT" ]; then # Default to port 7000
      INITIAL_PORT=7000
    fi

    if [ -z "$MASTERS" ]; then # Default to 3 masters
      MASTERS=3
    fi

    if [ -z "$SLAVES_PER_MASTER" ]; then # Default to 1 slave for each master
      SLAVES_PER_MASTER=1
    fi

    if [ -z "$BIND_ADDRESS" ]; then # Default to any IPv4 address
      BIND_ADDRESS=0.0.0.0
    fi

    max_port=$(($INITIAL_PORT + $MASTERS * ( $SLAVES_PER_MASTER  + 1 ) - 1))
    first_standalone=$(($max_port + 1))
    if [ "$STANDALONE" = "true" ]; then
      STANDALONE=2
    fi
    if [ ! -z "$STANDALONE" ]; then
      max_port=$(($max_port + $STANDALONE))
    fi

    for port in $(seq $INITIAL_PORT $max_port); do
      mkdir -p /valkey-conf/${port}
      mkdir -p /valkey-data/${port}

      if [ -e /valkey-data/${port}/nodes.conf ]; then
        rm /valkey-data/${port}/nodes.conf
      fi

      if [ -e /valkey-data/${port}/dump.rdb ]; then
        rm /valkey-data/${port}/dump.rdb
      fi

      if [ -e /valkey-data/${port}/appendonly.aof ]; then
        rm /valkey-data/${port}/appendonly.aof
      fi

      # base environment
      export PORT=$port
      export TLS_PORT=
      export CLUSTER_BUS_PORT=
      export NODE_PORT=$port
      export VALKEY_PASSWORD=${VALKEY_PASSWORD:-}
      export BIND_ADDRESS=$BIND_ADDRESS

      # adjust for TLS
      if [ "$TLS_ENABLED" = "true" ]; then
        export PORT=0
        export TLS_PORT=$port
        export CLUSTER_BUS_PORT=$((port + 10000))
      fi

      # choose template
      if [ "$port" -lt "$first_standalone" ]; then
        tmpl=/valkey-conf/valkey-cluster.tmpl
        nodes="$nodes $IP:$port"
      else
        tmpl=/valkey-conf/valkey.tmpl
      fi

      # render config
      envsubst < "$tmpl" > "/valkey-conf/${port}/valkey.conf"

      # append TLS stanza if needed
      if [ -n "$TLS_PORT" ] && [ "$tmpl" = "/valkey-conf/valkey-cluster.tmpl" ]; then
        cat >> "/valkey-conf/${port}/valkey.conf" <<EOF
cluster-port $CLUSTER_BUS_PORT
tls-cluster yes
tls-replication yes
tls-auth-clients ${TLS_AUTH_CLIENTS:-no}
tls-port $TLS_PORT
tls-cert-file $TLS_CERT_FILE
tls-key-file $TLS_KEY_FILE
tls-ca-cert-file $TLS_CA_CERT_FILE
EOF
      fi

      if [ "$port" -lt $(($INITIAL_PORT + $MASTERS)) ]; then
        if [ "$SENTINEL" = "true" ]; then
          PORT=${port} SENTINEL_PORT=$((port - 2000)) envsubst < /valkey-conf/sentinel.tmpl > /valkey-conf/sentinel-${port}.conf
          cat /valkey-conf/sentinel-${port}.conf
        fi
      fi

    done

    bash /generate-supervisor-conf.sh $INITIAL_PORT $max_port > /etc/supervisor/supervisord.conf

    supervisord -c /etc/supervisor/supervisord.conf
    sleep 3

    #
    ## Check the version of valkey-cli and if we run on a valkey server below 5.0
    ## If it is below 5.0 then we use the valkey-trib.rb to build the cluster
    #
    /valkey/src/valkey-cli --version | grep -E "valkey-cli 3.0|valkey-cli 3.2|valkey-cli 4.0"

    CLI_ARGS=""
    if [ ! -z "$VALKEY_PASSWORD" ]; then
      CLI_ARGS="$CLI_ARGS -a '$VALKEY_PASSWORD'"
    fi

    if [ "$TLS_ENABLED" = "true" ]; then
       # valkey-cli needs these flags to connect to the nodes we just spawned
       CLI_ARGS="$CLI_ARGS --tls --cert $TLS_CERT_FILE --key $TLS_KEY_FILE --cacert $TLS_CA_CERT_FILE --insecure"
    fi

    echo "Using valkey-cli to create the cluster"
    echo "yes" | valkey-cli --cluster create $nodes --cluster-replicas "$SLAVES_PER_MASTER" $CLI_ARGS

    if [ "$SENTINEL" = "true" ]; then
      for port in $(seq $INITIAL_PORT $(($INITIAL_PORT + $MASTERS))); do
        valkey-sentinel /valkey-conf/sentinel-${port}.conf &
      done
    fi

    tail -f /var/log/supervisor/valkey*.log
else
  exec "$@"
fi
