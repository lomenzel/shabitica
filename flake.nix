{
  description = "shabitica flake";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/21.05";

  outputs = { nixpkgs, ... }: {
    nixosModules.default = (args: import ./modules (args // { pkgs = import nixpkgs { system = args.config.nixpkgs.localSystem.system; }; }) );
  };
}
