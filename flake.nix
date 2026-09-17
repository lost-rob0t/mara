{
  description = "Mara Emacs companion runtime";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenvNoCC.mkDerivation {
          pname = "mara-emacs";
          version = "0.2.0";
          src = self;

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/emacs/site-lisp/mara"
            mkdir -p "$out/share/emacs/site-lisp/zara-plugin"
            cp emacs/*.el "$out/share/emacs/site-lisp/mara/"
            cp zara-plugin/mara_bridge.py "$out/share/emacs/site-lisp/zara-plugin/"
            runHook postInstall
          '';
        };
      });
    };
}
