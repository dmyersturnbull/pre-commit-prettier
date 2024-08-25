prettier mirror
===============

Mirror of prettier package for pre-commit. Adjusted to work with prettier version 3 and above.

For pre-commit: see https://github.com/pre-commit/pre-commit

For prettier: see https://github.com/prettier/prettier


### Using prettier with pre-commit

Add this to your `.pre-commit-config.yaml`:

```yaml
-   repo: https://github.com/JoC0de/pre-commit-prettier
    rev: ''  # Use the sha / tag you want to point at
    hooks:
    -   id: prettier
```

When using plugins with `prettier` you'll need to declare them under
`additional_dependencies`. For example:

```yaml
-   repo: https://github.com/JoC0de/pre-commit-prettier
    rev: ''  # Use the sha / tag you want to point at
    hooks:
    -   id: prettier
        additional_dependencies:
        -   prettier@3.3.3
        -   '@prettier/plugin-xml@3.4.1'
```

By default, all files are passed to `prettier`, if you want to limit the
file list, adjust `types` / `types_or` / `files`:

```yaml
    -   id: prettier
        types_or: [css, javascript]
```
