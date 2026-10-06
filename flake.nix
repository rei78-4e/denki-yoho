{
  description = "Battery remaining-time forecast from upower history";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          denki-yoho = pkgs.stdenv.mkDerivation {
            pname = "denki-yoho";
            version = "0.2.0";
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./build.zig
                ./build.zig.zon
                ./src
                ./README.md
                ./LICENSE
              ];
            };

            nativeBuildInputs = [ pkgs.zig_0_16.hook ];
            dontSetZigDefaultFlags = true;
            zigBuildFlags = [
              "-Dcpu=baseline"
              "--release=small"
            ];

            postInstall = ''
              install -Dm644 README.md $out/share/doc/denki-yoho/README.md
            '';

            meta = {
              description = "Battery remaining-time forecast from upower history";
              license = pkgs.lib.licenses.mit;
              mainProgram = "denki-yoho";
              platforms = pkgs.lib.platforms.linux;
            };
          };
          default = denki-yoho;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.default;
          meta.description = "Run denki-yoho";
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              zig_0_16
              zls
            ];
          };
        }
      );
    };
}
