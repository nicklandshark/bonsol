{
  description = "Build a cargo workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane.url = "github:ipetkov/crane";

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-analyzer-src.follows = "";
    };

    flake-utils.url = "github:numtide/flake-utils";

    nix-core = {
      url = "github:Cloud-Scythe-Labs/nix-core";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.fenix.follows = "fenix";
    };

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crane, fenix, flake-utils, nix-core, advisory-db, ... }:
    with flake-utils.lib;
    eachSystem (with system; [
        # Currently only known to run on x86-linux but this may change soon
        x86_64-linux
      ]) (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        inherit (pkgs) lib;

        rustToolchain = nix-core.toolchains.${system}.mkRustToolchainFromTOML
          ./rust-toolchain.toml
          "sha256-VZZnlyP69+Y3crrLHQyJirqlHrTtGTsyiSnZB8jEvVo=";
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain.fenix-pkgs;
        craneLibLLvmTools = craneLib.overrideToolchain
          (fenix.packages.${system}.complete.withComponents [
            "cargo"
            "llvm-tools"
            "rustc"
          ]);
        workspace = rec {
          root = ./.;
          src = craneLib.cleanCargoSource root;
          canonicalizePath = crate: root + "/${crate}";
          canonicalizePaths = crates: map (crate: canonicalizePath crate) crates;
        };

        # Common arguments can be set here to avoid repeating them later
        commonArgs = {
          inherit (workspace) src;
          strictDeps = true;

          buildInputs = with pkgs; [
            (r0vm.overrideAttrs {
              version = "1.0.1";
            })
            solana-cli
          ];
        };

        # Build *just* the cargo dependencies (of the entire workspace),
        # so we can reuse all of that work (e.g. via cachix) when running in CI
        # It is *highly* recommended to use something like cargo-hakari to avoid
        # cache misses when building individual top-level-crates
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        individualCrateArgs = commonArgs // {
          inherit cargoArtifacts;
          inherit (craneLib.crateNameFromCargoToml { inherit src; }) version;
          doCheck = false;
        };

        # Function for including a set of files for a specific crate,
        # avoiding unnecessary files.
        fileSetForCrate = crate: deps: lib.fileset.toSource {
          inherit (workspace) root;
          fileset = lib.fileset.unions ([
            ./Cargo.toml
            ./Cargo.lock
            (workspace.canonicalizePath crate)
          ] ++ (workspace.canonicalizePaths deps));
        };

        # Build the top-level crates of the workspace as individual derivations.
        # This allows consumers to only depend on (and build) only what they need.
        # Though it is possible to build the entire workspace as a single derivation,
        # in this case the workspace itself is not a package.
        #
        # Function for creating a crate derivation, which takes the relative path
        # to the crate as a string, and a list of any of the workspace crates
        # that it will need in order to build.
        # NOTE: All paths exclude the root, eg "my/dep" not "./my/dep". Root is mapped
        # during file set construction.
        #
        # Example:
        # ```nix
        #   my-crate =
        #     let
        #       deps = [ "path/to/dep1" "path/to/dep2" ];
        #     in
        #     mkCrateDrv "path/to/crate" deps;
        # ```
        mkCrateDrv = crate: deps:
          let
            manifest = craneLib.crateNameFromCargoToml {
              cargoToml = ((workspace.canonicalizePath crate) + "/Cargo.toml");
            };
          in
          craneLib.buildPackage (individualCrateArgs // {
            inherit (manifest) version pname;
            cargoExtraArgs = "--locked --bin ${manifest.pname}";
            src = fileSetForCrate crate deps;
          });

        bonsol-cli = mkCrateDrv "cli" [ "sdk" "onchain" "schemas-rust" ];

        # Internally managed version of `cargo-risczero` that is pinned to
        # the version that bonsol relies on.
        cargo-risczero = pkgs.callPackage ./nixos/pkgs/cargo-risczero { };
      in
      {
        checks = {
          # Build the crates as part of `nix flake check` for convenience
          inherit
            bonsol-cli
            cargo-risczero;

          # Run clippy (and deny all warnings) on the workspace source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          # TODO: uncomment once all clippy lints are fixed
          # workspace-clippy = craneLib.cargoClippy (commonArgs // {
          #   inherit cargoArtifacts;
          #   cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          # });

          workspace-doc = craneLib.cargoDoc (commonArgs // {
            inherit cargoArtifacts;
          });

          # Check formatting
          workspace-fmt = craneLib.cargoFmt {
            inherit (workspace) src;
          };

          workspace-toml-fmt = craneLib.taploFmt {
            src = pkgs.lib.sources.sourceFilesBySuffices workspace.src [ ".toml" ];
            # taplo arguments can be further customized below as needed
            # taploExtraArgs = "--config ./taplo.toml";
          };

          # Audit dependencies
          # TODO: Uncoment once all audits are fixed
          # workspace-audit = craneLib.cargoAudit {
          #   inherit (workspace) src;
          #   inherit advisory-db;
          # };

          # Audit licenses
          workspace-deny = craneLib.cargoDeny {
            inherit (workspace) src;
          };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on other crate derivations
          # if you do not want the tests to run twice
          workspace-nextest = craneLib.cargoNextest (commonArgs // {
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
          });

          # TODO: Consider using cargo-hakari workspace hack for dealing with
          # the unsightly requirements of the iop crate.
          # Ensure that cargo-hakari is up to date
          # workspace-hakari = craneLib.mkCargoDerivation {
          #   inherit src;
          #   pname = "my-workspace-hakari";
          #   cargoArtifacts = null;
          #   doInstallCargoArtifacts = false;

          #   buildPhaseCargoCommand = ''
          #     cargo hakari generate --diff  # workspace-hack Cargo.toml is up-to-date
          #     cargo hakari manage-deps --dry-run  # all workspace crates depend on workspace-hack
          #     cargo hakari verify
          #   '';

          #   nativeBuildInputs = [
          #     pkgs.cargo-hakari
          #   ];
          # };
        };

        packages = {
          inherit
            bonsol-cli
            cargo-risczero;
        } // lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
          my-workspace-llvm-coverage = craneLibLLvmTools.cargoLlvmCov (commonArgs // {
            inherit cargoArtifacts;
          });
        };

        apps = { };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};
          packages = with pkgs; [
            nil # nix lsp
            nixpkgs-fmt # nix formatter
            # pkgs.cargo-hakari
          ] ++ [
            self.packages.${system}.cargo-risczero
          ];
        };

        # Run nix fmt to format nix files in file tree
        # using the specified formatter
        formatter = pkgs.nixpkgs-fmt;
      });
}