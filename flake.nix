{
  description = "omamac — Omarchy-style theming for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      packages = forAll (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "omamac";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            mkdir -p $out/share/omamac $out/bin
            cp -r bin lib render themes menu hammerspoon $out/share/omamac/

            # Every verb resolves siblings through OMAMAC_DIR, so one wrapper
            # on the dispatcher is enough.
            makeWrapper $out/share/omamac/bin/omamac $out/bin/omamac \
              --set OMAMAC_DIR $out/share/omamac \
              --prefix PATH : ${pkgs.lib.makeBinPath [
                pkgs.jq pkgs.curl pkgs.fontconfig pkgs.bash
              ]}
          '';
        };
      });

      checks = forAll (pkgs: {
        tests = pkgs.runCommand "omamac-tests" { buildInputs = [ pkgs.bash pkgs.jq ]; } ''
          cp -r ${./.} src && chmod -R +w src && cd src
          bash tests/run && touch $out
        '';
      });
    };
}
