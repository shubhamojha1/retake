{
  description = "retake — Phoenix + Rust renderer + React; open-source AI video editor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        # Pinned by flake.lock. Phase 1 renders natively; no wasm target yet
        # (WASM preview is Phase 4).
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
          ];
        };

        baseDeps = with pkgs; [
          # Elixir toolchain (erlang 27 / elixir 1.18).
          erlang_27
          beam.packages.erlang_27.elixir_1_18

          # Web toolchain
          nodejs_22

          # Renderer toolchain. ffmpeg is pinned by flake.lock: determinism
          # (D12) holds only for the same ffmpeg build.
          rustToolchain
          pkg-config
          ffmpeg

          # Database (local dev instance lives in .pg/, see `just pg-*`)
          postgresql_17

          # Tooling used by the justfile
          just
          jq
        ];

        devExtra =
          if builtins.getEnv "CI" != "true" then
            with pkgs;
            [
              nixfmt-rfc-style
            ]
          else
            [ ];

        all = baseDeps ++ devExtra;

        inherit (pkgs) inotify-tools;
        inherit (pkgs.lib) optionals;
        inherit (pkgs.stdenv) isLinux;

        linuxDeps = optionals isLinux [ inotify-tools ];
      in
      {
        devShells = {
          default = pkgs.mkShell {
            packages = all ++ linuxDeps;
            shellHook = ''
              # this allows mix to work on the local directory
              mkdir -p .nix-mix .nix-hex
              export MIX_HOME=$PWD/.nix-mix
              export HEX_HOME=$PWD/.nix-hex
              # make hex from Nixpkgs available
              # `mix local.hex` will install hex into MIX_HOME and should take precedence
              export MIX_PATH="${pkgs.beam.packages.erlang_27.hex}/lib/erlang/lib/hex/ebin"
              export PATH=${pkgs.erlang_27}/bin:$MIX_HOME/bin:$HEX_HOME/bin:$MIX_HOME/escripts:$PWD/bin:$PATH
              export LANG=C.UTF-8
              # keep your shell history in iex
              export ERL_AFLAGS="-kernel shell_history enabled"

              export MIX_ENV=dev

              # local Postgres: TCP on 127.0.0.1:5432, trust auth, data in .pg/
              export PGDATA=$PWD/.pg/data
              export PGHOST=127.0.0.1
              export PGPORT=5432
              export PGUSER=postgres
            '';
          };
        };
      }
    );
}
