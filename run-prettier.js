#!/usr/bin/env node

"use strict";

import { readFileSync, readdirSync, existsSync } from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import url from "node:url";

const nodePath = path.resolve(process.env.NODE_PATH);
const pluginsPath = path.resolve(nodePath, "@prettier");

let plugins = [];

if (existsSync(pluginsPath)) {
  plugins = readdirSync(pluginsPath, { withFileTypes: true });
}

// if there is a plugin added using '--plugin=<plugin-name>' command line argument
// we add them to the plugins list searching them inside the node folder
for (let argumentIndex = process.argv.length - 1; argumentIndex >= 0; argumentIndex--) {
  const argument = process.argv[argumentIndex];
  if (!argument.startsWith("--plugin=")) {
    continue;
  }

  const pluginName = argument.slice("--plugin=".length);
  const matchingDirectories = readdirSync(nodePath, { withFileTypes: true }).filter(
    (pluginPath) => pluginPath.isDirectory() && pluginPath.name.localeCompare(pluginName, "en", { sensitivity: "base" }) === 0
  );

  if (matchingDirectories.length === 0) {
    continue;
  }

  // consume the command line argument
  process.argv.splice(argumentIndex, 1);

  plugins.push(
    ...matchingDirectories.filter((directory) =>
      plugins.every((existing) => directory.parentPath !== existing.parentPath && directory.name !== existing.name)
    )
  );
}

// neither single nor double quotes are supported around the path.
const additionalArguments = plugins
  .filter((pluginPath) => pluginPath.isDirectory())
  .flatMap((pluginPath) => {
    const pluginDirectoryPath = path.join(pluginPath.parentPath, pluginPath.name);
    let pluginImportPath;
    try {
      const packageJsonPath = path.join(pluginDirectoryPath, "package.json");
      const packageJsonContent = readFileSync(packageJsonPath, "utf-8");
      const packageJson = JSON.parse(packageJsonContent);
      if (packageJson.exports && packageJson.exports["."]) {
        if (typeof packageJson.exports["."] === "string") {
          pluginImportPath = path.join(pluginDirectoryPath, packageJson.exports["."]);
        } else if (packageJson.exports["."].default) {
          pluginImportPath = path.join(pluginDirectoryPath, packageJson.exports["."].default);
        }
      }

      if (pluginImportPath) {
        // path defined by 'exports'
      } else if (packageJson.main) {
        pluginImportPath = path.join(pluginDirectoryPath, packageJson.main);
      } else if (packageJson.module) {
        pluginImportPath = path.join(pluginDirectoryPath, packageJson.module);
      } else {
        pluginImportPath = pluginDirectoryPath;
      }
    } catch (error) {
      console.error(`Error '${error}' reading or parsing package.json from '${pluginDirectoryPath}'`);
      pluginImportPath = pluginDirectoryPath;
    }

    const pluginImportFileUrl = url.pathToFileURL(pluginImportPath);
    return ["--plugin", pluginImportFileUrl.toString()];
  });

// Use '--experimental-cli' if it's available AND 'PRETTIER_EXPERIMENTAL_CLI' isn't set.
// ('PRETTIER_EXPERIMENTAL_CLI' is a string, and "0" is truthy.)
// Assume that, if '--experimental-cli' isn't available, it's now the default.
if (!process.argv.includes("--experimental-cli") && !process.env.PRETTIER_EXPERIMENTAL_CLI) {
  additionalArguments.push("--experimental-cli");
}

// the first two items of process.argv are reserved (the node.exe and the current file name) so insert after them
process.argv.splice(2, 0, ...additionalArguments);

// Override stdout.write to filter message that end with "(unchanged)"
// prettier currently logs messages when a file is not changed we are not interested in them
const originalWrite = process.stdout.write;
process.stdout.write = function (message, ...optionalParams) {
  if (typeof message === "string" && message.includes(" (unchanged)")) {
    return;
  }

  originalWrite.apply(process.stdout, [message, ...optionalParams]);
};

const requireImport = createRequire(import.meta.url);
const runPrettier = requireImport("prettier/bin/prettier.cjs");
await runPrettier;
