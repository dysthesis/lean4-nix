npmlock2nix: {
  pkgs,
  lib,
  stdenv,
  lean,
  bubblewrap,
  # NOTE: Since mkPackage builds dependencies recursively, I'm not sure if there
  # are any better way to define per-dependency build inputs. The only viable
  # alternative that I can think of is to make a repository of per-package
  # derivations.
  extraBuildInputs ? [],
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

  # Perform the lake build step in a bubblewrap sandbox to prevent it from
  # touching the Nix store. Taken from:
  # https://github.com/nix-community/nur-combined/blob/39580589ffb5b158387bb5911b178e388735eaed/repos/wrvsrx/pkgs/lean-packages/mathlib/default.nix
  mkLakeBuildStep = {
    deps ? {},
    roots ? [],
    lakeManifestPath ? null,
    useBubblewrap ? true,
  }: let
    lakeManifestArgs =
      lib.optionals (lakeManifestPath != null)
      ["--packages=${lakeManifestPath}"];

    rootsArgs =
      lib.optionals (roots != [])
      ["#${builtins.concatStringsSep " " roots}"];

    commandArgs =
      ["lake" "build"]
      ++ lakeManifestArgs
      ++ rootsArgs;

    depPaths = lib.attrValues deps;
  in
    if useBubblewrap
    then
      # sh
      ''
        bubblewrapArgs=(--dev-bind / /)
        # Provide npm with a writable home/cache; the default /homeless-shelter is
        # missing inside the bubblewrap namespace and causes npm to crash before
        # doing any work.
        tmpHome="''${TMPDIR:-/tmp}/lake-npm-home"
        mkdir -p "''${tmpHome}/.npm/_logs" "''${tmpHome}/.cache"
        export HOME="''${tmpHome}"
        export NPM_CONFIG_CACHE="''${tmpHome}/.npm"
        export XDG_CACHE_HOME="''${tmpHome}/.cache"
        bubblewrapArgs+=(--setenv HOME "''${HOME}")
        bubblewrapArgs+=(--setenv NPM_CONFIG_CACHE "''${NPM_CONFIG_CACHE}")
        bubblewrapArgs+=(--setenv XDG_CACHE_HOME "''${XDG_CACHE_HOME}")
        for pkg in ${lib.concatStringsSep " " depPaths}; do
          if [ -d "$pkg/lib/lean-packages" ]; then
            bubblewrapArgs+=(--tmpfs "$pkg/lib/lean-packages/*/.lake/build")
            bubblewrapArgs+=(--tmpfs "$pkg/lib/lean-packages/*/.lake/config")
          else
            bubblewrapArgs+=(--tmpfs "$pkg/.lake/build")
            bubblewrapArgs+=(--tmpfs "$pkg/.lake/config")
          fi
        done
        bwrap "''${bubblewrapArgs[@]}" ${lib.concatStringsSep " " commandArgs}
      ''
    else ''
      ${lib.concatStringsSep " " commandArgs}
    '';

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
    stdenv.mkDerivation ({
        buildInputs =
          [
            lean.lean-all
            bubblewrap
          ]
          ++ extraBuildInputs;

        configurePhase = ''
          runHook preConfigure
          ${lib.concatMapStringsSep "\n" (phase: ''
            if [ -n "''${${phase}:-}" ]; then
              echo "Running ${phase}"
              eval "''${${phase}}"
            fi
          '') (args.preConfigurePhases or [])}
          rm lake-manifest.json
          ln -s ${replaceManifest}lake-manifest.json
          # Ensure the bubblewrap mountpoint for dependency configs exists before the store becomes read-only
          mkdir -p .lake/config
          runHook postConfigure
        '';

        buildPhase = ''
          runHook preBuild
          ${mkLakeBuildStep {inherit deps;}}
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
      // (builtins.removeAttrs args ["deps"]));
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
    mkLakeDerivation ( {
        inherit src;
        inherit (manifest) name;
        deps = manifestDeps;
        nativeBuildInputs = staticLibDeps;
        buildPhase =
          args.buildPhase
          or ''
            runHook preBuild
            ${mkLakeBuildStep {
              deps = manifestDeps;
              inherit roots;
            }}
            runHook postBuild
          '';
        installPhase =
          args.installPhase
          or 
          # sh
          ''
            runHook preInstall
            mkdir $out
            if [ -d .lake/build/bin ]; then
              mv .lake/build/bin $out/
            fi
            if [ -d .lake/build/lib ]; then
              mv .lake/build/lib $out/
            fi
            # Preserve an empty .lake/config so downstream bubblewrap mounts have a writable target
            if [ -d .lake/config ]; then
              mkdir -p $out/.lake
              cp -r .lake/config $out/.lake/
            else
              mkdir -p $out/.lake/config
            fi
            runHook postInstall
          '';
      }
      // (actualDepOverride.${manifest.name} or {}));
in {inherit mkLakeDerivation mkPackage;}
