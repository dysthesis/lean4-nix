npmlock2nix: {
  pkgs,
  lib,
  stdenv,
  lean,
}: let
  capitalize = s: let
    first = lib.toUpper (builtins.substring 0 1 s);
    rest = builtins.substring 1 (-1) s;
  in
    first + rest;
  importLakeManifest = manifestFile: let
    manifest = lib.importJSON manifestFile;
  in
    lib.warnIf (manifest.version != "1.1.0") ("Unknown version: " + builtins.toString manifest.version) manifest;
  # A wrapper around `mkDerivation` which sets up the lake manifest
  mkLakeDerivation = args @ {
    name,
    src,
    deps ? {},
    ...
  }: let
    manifest = importLakeManifest "${src}/lake-manifest.json";
    # create a surrogate manifest
    replaceManifest =
      pkgs.writers.writeJSON "lake-manifest.json"
      (
        lib.setAttr manifest "packages" (builtins.map ({
            name,
            inherited ? false,
            ...
          }: {
            inherit name inherited;
            type = "path";
            dir = deps.${name};
          })
          manifest.packages)
      );
  in
    stdenv.mkDerivation (
      {
        buildInputs = [lean.lean-all];

        configurePhase = ''
          runHook preConfigure
          ${lib.concatMapStringsSep "\n" (phase: ''
            if [ -n "''${${phase}:-}" ]; then
              echo "Running ${phase}"
              eval "''${${phase}}"
            fi
          '') (args.preConfigurePhases or [])}
          rm lake-manifest.json
          ln -s ${replaceManifest} lake-manifest.json
          runHook postConfigure
        '';

        buildPhase = ''
          runHook preBuild
          lake build
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out/
          mv * $out/
          mv .lake $out/
          runHook postInstall
        '';
      }
      // (builtins.removeAttrs args ["deps"])
    );
  # Builds a Lean package by reading the manifest file.
  mkPackage = args @ {
    # Path to the source
    src,
    # Path to the directory containing package.json and package-lock.json (null if no npm deps)
    nodeSrc ? null,
    # Relative path from project root to where node_modules should be placed
    nodeModulesPath ? ".",
    # Path to the `lake-manifest.json` file
    manifestFile ? "${src}/lake-manifest.json",
    # Root module
    roots ? null,
    # Static library dependencies
    staticLibDeps ? [],
    # Override derivation args in dependencies
    depOverride ? {},
    ...
  }: let
    manifest = importLakeManifest manifestFile;

    roots =
      args.roots or [(capitalize manifest.name)];

    # Compute node_modules derivation if nodeSrc provided
    nodeModules =
      if nodeSrc != null
      then npmlock2nix.node_modules {src = nodeSrc;}
      else null;

    # Merge npm setup into depOverride for root package
    actualDepOverride =
      if nodeModules != null
      then
        depOverride
        // {
          ${manifest.name} =
            (depOverride.${manifest.name} or {})
            // {
              preConfigurePhases = (depOverride.${manifest.name}.preConfigurePhases or []) ++ ["setupNodeModules"];
              setupNodeModules = ''
                echo "Setting up node_modules at ${nodeModulesPath}"
                mkdir -p ${nodeModulesPath}
                ln -sf ${nodeModules}/node_modules ${nodeModulesPath}/node_modules
              '';
              nativeBuildInputs = (depOverride.${manifest.name}.nativeBuildInputs or []) ++ [nodeModules];
            };
        }
      else depOverride;

    depSources = builtins.listToAttrs (builtins.map (info: {
        inherit (info) name;
        value = builtins.fetchGit {
          inherit (info) url rev;
          shallow = true;
        };
      })
      manifest.packages);
    # construct dependency name map
    flatDeps =
      lib.mapAttrs (
        _name: src: let
          manifest = importLakeManifest "${src}/lake-manifest.json";
          deps = builtins.map ({name, ...}: name) manifest.packages;
        in
          deps
      )
      depSources;

    # Build all dependencies
    manifestDeps = builtins.listToAttrs (builtins.map (info: let
        depOverrideForPkg = depOverride.${info.name} or {};
        depNpmConfig = depOverrideForPkg.npm or null;
        depNodeModules =
          if depNpmConfig != null
          then let
            depNodeSrc = depSources.${info.name} + "/${depNpmConfig.nodeSubdir}";
          in
            npmlock2nix.node_modules {src = depNodeSrc;}
          else null;
      in {
        inherit (info) name;
        value = mkLakeDerivation (
          {
            inherit (info) name url;
            src = depSources.${info.name};
            deps = builtins.listToAttrs (builtins.map (name: {
                inherit name;
                value = manifestDeps.${name};
              })
              flatDeps.${info.name});
          }
          // (builtins.removeAttrs depOverrideForPkg ["npm"])
          // (
            if depNpmConfig != null
            then {
              preConfigurePhases = (depOverrideForPkg.preConfigurePhases or []) ++ ["setupNodeModules"];
              setupNodeModules = ''
                echo "Setting up node_modules for dependency ${info.name} at ${depNpmConfig.nodeSubdir}"
                mkdir -p ${depNpmConfig.nodeSubdir}
                ln -sf ${depNodeModules}/node_modules ${depNpmConfig.nodeSubdir}/node_modules
              '';
              nativeBuildInputs = (depOverrideForPkg.nativeBuildInputs or []) ++ [depNodeModules];
            }
            else {}
          )
        );
      })
      manifest.packages);
  in
    mkLakeDerivation ({
        inherit src;
        inherit (manifest) name;
        deps = manifestDeps;
        nativeBuildInputs = staticLibDeps;
        buildPhase =
          args.buildPhase
          or ''
            runHook preBuild
            lake build #${builtins.concatStringsSep " " roots}
            runHook postBuild
          '';
        installPhase =
          args.installPhase
          or ''
            runHook preInstall
            mkdir $out
            if [ -d .lake/build/bin ]; then
              mv .lake/build/bin $out/
            fi
            if [ -d .lake/build/lib ]; then
              mv .lake/build/lib $out/
            fi
            runHook postInstall
          '';
      }
      // (actualDepOverride.${manifest.name} or {}));
in {
  inherit mkLakeDerivation mkPackage;
}
