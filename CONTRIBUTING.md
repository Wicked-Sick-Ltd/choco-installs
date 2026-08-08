# Contributing to choco-installs

Thanks for contributing!

## How to contribute

1. Fork the repository.
2. Create a feature branch from the default branch.
3. Make your changes.
4. Open a pull request with a clear description of:
   - what changed
   - why it changed
   - any validation/testing done

## Contribution guidelines

- Keep package additions/removals focused and intentional.
- Prefer widely used, stable packages.
- Avoid bundling unrelated changes in one PR.
- Keep scripts readable and idempotent where possible.

## Testing changes

Before opening a PR:

- Validate script syntax in PowerShell.
- Test on a clean Windows VM when feasible.
- Confirm package names are valid Chocolatey identifiers.

## Pull request checklist

- [ ] I tested the change locally.
- [ ] I documented any behavior changes.
- [ ] I kept the PR focused on a single concern.

## Code of Conduct

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
