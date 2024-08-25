#!/usr/bin/env node

"use strict";

import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { run as runPrettier } from "prettier/internal/cli.mjs";

const pluginsPath = path.resolve(process.env.NODE_PATH, "@prettier");

const plugins = readdirSync(pluginsPath, { withFileTypes: true });

// neither single nor double quotes are supported around the path.
const additionalArguments = plugins
  .filter((pluginPath) => pluginPath.isDirectory())
  .flatMap((pluginPath) => {
    const pluginDirectoryPath = path.join(
      pluginPath.parentPath,
      pluginPath.name
    );
    let pluginImportPath;
    try {
      const packageJsonPath = path.join(pluginDirectoryPath, "package.json");
      const packageJsonContent = readFileSync(packageJsonPath, "utf-8");
      const packageJson = JSON.parse(packageJsonContent);
      if (packageJson.exports && packageJson.exports["."]) {
        if (typeof packageJson.exports["."] === "string") {
          pluginImportPath = path.join(pluginDirectoryPath, packageJson.exports["."]);
        } else if (packageJson.exports["."].default) {
          pluginImportPath = path.join(
            pluginDirectoryPath,
            packageJson.exports["."].default
          );
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
      console.error(
        `Error '${error}' reading or parsing package.json from '${pluginDirectoryPath}'`
      );
      pluginImportPath = pluginDirectoryPath;
    }
    return ["--plugin", pluginImportPath];
  });

// the first two items of process.argv are reserved (the node.exe and the current file name) so insert after them
process.argv.splice(2, 0, ...additionalArguments);

runPrettier();
