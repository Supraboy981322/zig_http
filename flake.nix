{
  description = "zig_http";

  inputs = {
    pkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig_overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig_overlay, flake-utils, ... } @ inputs: 
    (flake-utils.lib.eachDefaultSystem (system:
      let
        repo_root = builtins.toString ./.;

        zigVersion = "0.16.0";
        zig = zig_overlay.packages.${system}.${zigVersion};

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig_overlay.overlays.default ];
        };

        zls = pkgs.zls_0_16.overrideAttrs { zig = zig; };

        packages = [ zig ];
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = packages;
          packages = packages ++ [ zls ];
        };
      })
    );
}
