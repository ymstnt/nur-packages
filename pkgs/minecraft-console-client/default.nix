{
  fetchFromGitHub,
  lib,
  buildDotnetModule,
  dotnetCorePackages,
}:

buildDotnetModule {
  pname = "minecraft-console-client";
  version = "20250522-285";
  src = fetchFromGitHub {
    owner = "MCCTeam";
    repo = "Minecraft-Console-Client";
    rev = "20250522-285";
    hash = "sha256-7rKWbLbRCnMmJ9pwqMYZZZujyxbX84g4rFQ/Ms/R+uE=";
  };

  projectFile = "MinecraftClient/MinecraftClient.csproj";
  nugetDeps = ./deps.json;

  dotnet-sdk = dotnetCorePackages.sdk_7_0;
  dotnet-runtime = dotnetCorePackages.runtime_7_0;

  meta = {
    mainProgram = "Minecraft-Console-Client";
    description = "FOSS program for converting IME dictionaries";
    homepage = "https://github.com/studyzy/imewlconverter";
    license = lib.licenses.gpl3Only;
  };
}

