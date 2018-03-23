{ config, pkgs, system, lib, ... }:

let
  habitica = pkgs.callPackage ./habitica.nix {
    nodePackages = lib.mapAttrs' (lib.const (attrs: {
      name = attrs.packageName;
      value = attrs;
    })) (import ./generated {
      inherit pkgs; inherit (config.nixpkgs) system;
    });
    habiticaConfig = config.habitica.config;
  };

  basePath = "${habitica}/lib/node_modules/habitica";
  basePathText = "\${habitica}/lib/node_modules/habitica";

in {
  options.habitica = {
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "habitica.headcounter.org";
      description = "The host name to use for Habitica.";
    };

    baseURL = lib.mkOption {
      type = lib.types.str;
      default = "https://habitica.headcounter.org";
      description = "The base URL to use for serving web site content.";
    };

    staticPath = lib.mkOption {
      type = lib.types.path;
      default = "${basePath}/dist-client";
      defaultText = "${basePathText}/dist-client";
      readOnly = true;
      description = "The path to the static assets of Habitica.";
    };

    apiDocPath = lib.mkOption {
      type = lib.types.path;
      default = "${basePath}/apidoc_build";
      defaultText = "${basePathText}/apidoc_build";
      readOnly = true;
      description = "The path to the API documentation.";
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
        ADMIN_EMAIL = "aszlig@nix.build";
        NODE_ENV = "production";
        BASE_URL = config.habitica.baseURL;
        NODE_DB_URI = "mongodb://%2Frun%2Fhabitica%2Fdb.sock";
        PORT = "/run/habitica.sock";
        SENDMAIL_PATH = "${config.security.wrapperDir}/sendmail";
        MAIL_FROM = "no-reply@headcounter.org";
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

      systemd.services.habitica-init = {
        description = "Initialize Habitica";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "habitica-statedir-init.service" ];
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
            net.bindIp = "/run/habitica/db.sock";
            net.unixDomainSocket.filePermissions = "0770";
            storage.dbPath = "/var/lib/habitica/db";
            processManagement.fork = false;
          });
        in "${pkgs.mongodb}/bin/mongod --config ${mongoDbCfg}";

        serviceConfig.User = "habitica-db";
        serviceConfig.Group = "habitica";
        serviceConfig.PrivateTmp = true;
        serviceConfig.PrivateNetwork = true;
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
        after = [ "habitica-init.service" "habitica-db.service" ];

        environment = lib.mapAttrs (lib.const toString) config.habitica.config;

        serviceConfig = {
          ExecStart = let
            websitePath = "${habitica}/lib/node_modules/habitica/website";
          in lib.concatMapStringsSep " " lib.escapeShellArg [
            "@${pkgs.nodejs-8_x}/bin/node" "habitica-server"
            "${websitePath}/transpiled-babel/index.js"
          ];

          User = "habitica";
          Group = "habitica";
          PrivateTmp = true;
          PrivateNetwork = true;
          WorkingDirectory = "${habitica}/lib/node_modules/habitica";
        };
      };
    }
    (lib.mkIf config.habitica.useNginx {
      services.nginx.virtualHosts.${config.habitica.hostName}.locations = {
        "/".root = config.habitica.staticPath;
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

        "/apidoc".alias = config.habitica.apiDocPath;
        "/apidoc".index = "index.html";
      };
    })
  ];
}
