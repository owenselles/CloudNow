# Repository Agent Checklist

For every task that changes repository content, complete this checklist before reporting the task as finished:

1. Read the pinned SwiftFormat and SwiftLint versions from the `README.md` **Linting** section. The README is the source of truth; do not assume previously installed versions are current.
2. Verify the executables match those exact versions.
3. Run the non-mutating checks from the repository root:

   ```bash
   swiftformat --lint --config .swiftformat CloudNow
   swiftlint --strict --config .swiftlint.yml CloudNow
   ```

4. Do not mark the task complete until both checks pass. If a local executable has the wrong version, use the pinned CI/pre-commit tool environment instead of running the mismatched executable.
5. Report both check results in the final response.

