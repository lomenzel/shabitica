{ config, pkgs, lib, ... }:

let
  cfg = config.habitica;

  mongodb = pkgs.mongodb.overrideAttrs (drv: {
    patches = (drv.patches or []) ++ [ patches/mongodb-systemd.patch ];
    buildInputs = (drv.buildInputs or []) ++ [ pkgs.systemd ];
    NIX_LDFLAGS = lib.toList (drv.NIX_LDFLAGS or []) ++ [ "-lsystemd" ];
  });

  habitica = pkgs.callPackages ./habitica.nix {
    habiticaConfig = cfg.config;
  };

  hostIsFqdn = builtins.match ".+\\..+" cfg.hostName != null;
  isFqdnText = "builtins.match \".+\\\\..+\" config.habitica.hostName != null";

  dbtools = pkgs.callPackage ./dbtools.nix {};

  docInfo = import ./docinfo.nix;

in {
  options.habitica = {
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      example = "habitica.example.org";
      description = "The host name to use for Habitica.";
    };

    adminMailAddress = lib.mkOption {
      type = lib.types.str;
      default = "root@localhost";
      example = "habitica-admin@example.org";
      description = "Email address of the administrator.";
    };

    backupInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "daily";
      description = ''
        If this value is not <literal>null</literal>, create database backups
        on the interval specified. The format is described in <citerefentry>
          <refentrytitle>systemd.time</refentrytitle>
          <manvolnum>7</manvolnum>
        </citerefentry>, specifically the notes about
        <literal>OnCalendar</literal>.

        Otherwise if the value is <literal>null</literal>, you can still
        trigger a database backup manually by issuing <command>systemctl start
        habitica-db-backup.service</command>.

        The database backups are stored in <option>backupDir</option>.
      '';
    };

    backupDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/backup/habitica";
      description = let
        inherit (docInfo) archiveExampleFilename;
        exampleFile = "<replaceable>${archiveExampleFilename}</replaceable>";
        examplePath = "<replaceable>backupDir</replaceable>/${exampleFile}";
        cmd = docInfo.dbrestore + examplePath;
      in ''
        The path where backups are stored as MongoDB archives. To restore such
        a backup, the command <command>${cmd}</command> can be used.
      '';
    };

    senderMailAddress = lib.mkOption {
      type = lib.types.str;
      default = "habitica@localhost";
      example = "habitica@example.org";
      description = "The email address to use for sending notifications.";
    };

    baseURL = lib.mkOption {
      type = lib.types.str;
      default = let
        defaultScheme = if cfg.useSSL then "https" else "http";
      in "${defaultScheme}://${cfg.hostName}";
      defaultText = let
        schemeText = "if config.habitica.useSSL then \"https\" else \"http\"";
        hostText = "config.habitica.hostName";
      in lib.literalExample "\"\${${schemeText}}://\${${hostText}}\"";
      description = ''
        The base URL to use for serving web site content.
        If the default is used the URL scheme is dependent on whether
        <option>useSSL</option> is enabled or not.
      '';
    };

    insecureDB = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
      description = ''
        This is only used for testing and not recommended in production. It
        disables the networking namespace for MongoDB and binds to <systemitem
        class="ipaddress">127.0.0.1</systemitem> as well, so local users can
        read and write to the database at will.
      '';
    };

    staticPath = lib.mkOption {
      type = lib.types.path;
      default = habitica.client;
      defaultText = lib.literalExample "habitica.client";
      readOnly = true;
      description = "The path to the static assets of Habitica.";
    };

    apiDocPath = lib.mkOption {
      type = lib.types.path;
      default = habitica.apidoc;
      defaultText = lib.literalExample "habitica.apidoc";
      readOnly = true;
      description = "The path to the API documentation.";
    };

    useSSL = lib.mkOption {
      type = lib.types.bool;
      default = hostIsFqdn;
      defaultText = lib.literalExample isFqdnText;
      description = ''
        Whether to allow HTTPS connections only. If <option>hostName</option>
        contains any dots the default is <literal>true</literal>, otherwise
        it's <literal>false</literal>.
      '';
    };

    useACME = lib.mkOption {
      type = lib.types.bool;
      default = cfg.useSSL;
      description = ''
        Whether to use ACME to get a certificate for the domain specified in
        <option>hostName</option>. Defaults to <literal>true</literal> if
        <option>useSSL</option> is enabled.
      '';
    };

    useNginx = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = "Whether to create a virtual host for nginx.";
    };

    config = lib.mkOption {
      type = with lib.types; attrsOf (either int str);
      description = "Configuration options to pass to Habitica.";
    };
  };

  config = lib.mkMerge [
    { habitica.config = {
        ADMIN_EMAIL = cfg.adminMailAddress;
        NODE_ENV = "production";
        BASE_URL = cfg.baseURL;
        NODE_DB_URI = "mongodb://%2Frun%2Fhabitica%2Fdb.sock";
        PORT = "/run/habitica.sock";
        SENDMAIL_PATH = "${config.security.wrapperDir}/sendmail";
        MAIL_FROM = cfg.senderMailAddress;
      };

      users.users.habitica-db = {
        description = "Habitica Database User";
        group = "habitica";
      };

      users.users.habitica = {
        description = "Habitica User";
        group = "habitica";
      };

      users.groups.habitica = {};

      environment.systemPackages = [ dbtools ];

      systemd.services.habitica-statedir-init = {
        description = "Initialize Habitica";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        unitConfig.ConditionPathExists = "!/var/lib/habitica";
        script = ''
          mkdir -p /var/lib/habitica/db /var/lib/habitica/data

          chmod 0710 /var/lib/habitica
          chown root:habitica /var/lib/habitica

          chmod 0700 /var/lib/habitica/db
          chown habitica-db:habitica /var/lib/habitica/db

          chmod 0700 /var/lib/habitica/data
          chown habitica:habitica /var/lib/habitica/data
        '';
      };

      systemd.services.habitica-secrets-init = {
        description = "Initialize Secrets for Habitica";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "habitica-statedir-init.service" ];
        unitConfig.ConditionPathExists = "!/var/lib/habitica/secrets.env";
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        serviceConfig.UMask = "0077";
        serviceConfig.ExecStart = pkgs.writeScript "init-secrets.py" ''
          #!${pkgs.python3Packages.python.interpreter}
          import random, secrets
          secrets = {
            'SESSION_SECRET': secrets.token_hex(random.randint(50, 300)),
            'SESSION_SECRET_KEY': secrets.token_hex(32),
            'SESSION_SECRET_IV': secrets.token_hex(16)
          }
          lines = [key + '="' + val + '"\n' for key, val in secrets.items()]
          open('/var/lib/habitica/secrets.env', 'w').write("".join(lines))
        '';
      };

      systemd.services.habitica-init = {
        description = "Initialize Habitica";
        wantedBy = [ "multi-user.target" ];
        after = [
          "local-fs.target"
          "habitica-statedir-init.service"
          "habitica-secrets-init.service"
        ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        unitConfig.ConditionPathExists = "!/run/habitica";
        script = ''
          mkdir -p /run/habitica
          chmod 0710 /run/habitica
          chown habitica-db:habitica /run/habitica
        '';
      };

      systemd.services.habitica-db = {
        description = "Habitica MongoDB Instance";
        wantedBy = [ "multi-user.target" ];
        after = [ "habitica-init.service" ];

        serviceConfig.ExecStart = let
          mongoDbCfg = pkgs.writeText "mongodb.conf" (builtins.toJSON {
            net.bindIp = "/run/habitica/db.sock"
                       + lib.optionalString cfg.insecureDB ",127.0.0.1";
            net.unixDomainSocket.filePermissions = "0770";
            storage.dbPath = "/var/lib/habitica/db";
            processManagement.fork = false;
          });
        in "${mongodb}/bin/mongod --config ${mongoDbCfg}";

        serviceConfig.Type = "notify";
        serviceConfig.User = "habitica-db";
        serviceConfig.Group = "habitica";
        serviceConfig.PrivateTmp = true;
        serviceConfig.PrivateNetwork = !cfg.insecureDB;
      };

      systemd.services.habitica-db-backup = {
        description = "Backup Habitica Database";
        after = [ "habitica-db.service" ];

        serviceConfig.Type = "oneshot";
        serviceConfig.PrivateTmp = true;
        serviceConfig.UMask = "0077";

        script = ''
          backupDir=${lib.escapeShellArg cfg.backupDir}
          mkdir -p "$backupDir"
          archiveFile="$(date +${docInfo.archiveDateFormat}).archive"
          ${dbtools}/bin/habitica-db-dump --archive="$backupDir/$archiveFile"
        '';
      };

      systemd.sockets.habitica = {
        description = "Habitica Socket";
        wantedBy = [ "sockets.target" ];
        socketConfig.ListenStream = "/run/habitica.sock";
        socketConfig.SocketMode = "0660";
        socketConfig.SocketUser = "root";
        socketConfig.SocketGroup = config.services.nginx.group;
      };

      systemd.services.habitica = {
        description = "Habitica";
        wantedBy = [ "multi-user.target" ];
        after = [ "habitica-init.service" "habitica-db.service" ];

        serviceConfig.Type = "notify";
        serviceConfig.TimeoutStartSec = "10min";
        serviceConfig.NotifyAccess = "all";
        serviceConfig.ExecStart = "${habitica.server}/bin/habitica-server";
        serviceConfig.User = "habitica";
        serviceConfig.Group = "habitica";
        serviceConfig.PrivateTmp = true;
        serviceConfig.PrivateNetwork = true;
        serviceConfig.EnvironmentFile = "/var/lib/habitica/secrets.env";
      };
    }
    (lib.mkIf cfg.useNginx {
      services.nginx.enable = lib.mkOverride 900 true;
      services.nginx.virtualHosts.${cfg.hostName} = {
        forceSSL = cfg.useSSL;
        enableACME = cfg.useACME;
        locations = {
          "/".root = cfg.staticPath;
          "/".index = "index.html";
          "/".tryFiles = "$uri $uri/ @backend";

          # This is ugly as hell and basically disables caching.
          # See https://github.com/NixOS/nixpkgs/issues/25485
          "/".extraConfig = ''
            if_modified_since off;
            add_header Last-Modified "";
            etag off;
          '';

          "@backend".proxyPass = "http://unix:/run/habitica.sock:";
          "@backend".extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header   X-Real-IP        $remote_addr;
            proxy_set_header   X-Forwarded-For  $proxy_add_x_forwarded_for;
            proxy_set_header   X-NginX-Proxy    true;
            proxy_set_header   Host             $http_host;
            proxy_set_header   Upgrade          $http_upgrade;
            proxy_redirect     off;
          '';

          "/apidoc".alias = cfg.apiDocPath;
          "/apidoc".index = "index.html";
        };
      };
    })
    (lib.mkIf (cfg.backupInterval != null) {
      systemd.timers.habitica-db-backup = {
        description = "Backup Habitica Database";
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = cfg.backupInterval;
        timerConfig.Persistent = true;
      };
    })
  ];
}
