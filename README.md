# pod-nugetizer v2

Set up your package repository once, then let nugetizer handle the release. It runs your source tests, builds Release packages, tests those packages as a consumer would, and publishes the same files to NuGet.org and GitHub.

Once you've completed the setup below, the publishing workflow is two lines:

```yaml
on: { push: { tags: ['v*'] } }
jobs: { publish: { uses: podnet-dev/pod-nugetizer/.github/workflows/default.yml@v2, secrets: { NUGET_USER: '${{ secrets.NUGET_USER }}' }, permissions: { contents: write, id-token: write } } }
```

## 1. Prepare your repository

A typical layout is:

```text
global.json
Directory.Build.props
Example.slnx
src/Example/Example.csproj
tests/Example.Tests/Example.Tests.csproj
tests/Example.IntegrationTests/Example.IntegrationTests.csproj
```

- **SDK:** specify the version in `global.json`; nugetizer installs it. Choose your test runner there too. We prefer Microsoft.Testing.Platform with `MSTest.Sdk`.
- **Build settings:** enable `UseArtifactsOutput` in shared props. Set `IsPackable=true` only on distributable projects and false on tests. Nugetizer evaluates packability with the candidate version and Release configuration.
- **Dependencies:** source projects use project references. If packing turns those references into separate package dependencies, include all required projects in the pack target—packing one project does not also pack its siblings.

The workflow runs on Ubuntu. Commands use your repository root, or the supplied `working-directory`. The default pack target is the root project or solution; use `pack-target` if discovery is ambiguous.

## 2. Set up the two test phases

### Source tests: before packing

Use a `ProjectReference` to the source project. Leave `NugetizerIntegrationTest` unset or false.

Nugetizer recognizes test projects through evaluated `IsTestProject=true` or native MTP's `IsTestingPlatformApplication=true`. Metadata queries are restore-free: if your test identity normally comes from a package import after restore, declare `IsTestProject=true` directly. `MSTest.Sdk` already provides the identity.

### Package integration tests: after packing

Mark the project explicitly and reference the exact candidate version:

```xml
<PropertyGroup>
  <NugetizerIntegrationTest>true</NugetizerIntegrationTest>
  <IsPackable>false</IsPackable>
</PropertyGroup>
<ItemGroup>
  <PackageReference Include="Your.Package" Version="[$(PackageUnderTestVersion)]" />
</ItemGroup>
```

Nugetizer supplies `PackageUnderTestVersion` and the staged package feed. It restores and runs these tests in Release, with a fresh package cache and per-target artifacts directory.

The package-test gate checks that:

- The restored target graph contains **at least one staged candidate package**. A project reference alone does not count.
- Each referenced candidate ID uses the intended version and matching package archive from this run's cache.
- Candidate files remain unchanged after integration tests, so publication uses the tested files.

Unrelated published dependencies are allowed, even if their versions happen to match the candidate. The gate checks candidate consumption, not complete behavioral coverage of every package.

**Discovery:** both test phases search `.csproj` files under `tests`, excluding generated `bin`, `obj`, and `artifacts` folders. Evaluated properties select the phase; filenames are just conventions. Explicit test targets may be projects, directories, or solutions, but must not mix source and integration tests. Omit a stage if your repository has no projects for it.

**Restore requirements:** permanent/private feeds belong in `nuget.config`. Package Source Mapping must permit the temporary candidate source; custom intermediate paths must honor `ArtifactsPath`. Otherwise use your own package-test setup and omit `integration`. Fresh extracted cache files are trusted after restore; archive verification is not a sandbox against a runner modifying them.

## 3. Configure publishing

NuGet Trusted Publishing replaces persistent publishing API keys with a short-lived credential issued to the GitHub workflow.

1. Create a policy for **your GitHub repository and caller workflow filename**, such as `cd-nuget.yml`—not nugetizer's repository or `default.yml`.
2. Select the NuGet package owner and exact package IDs. Grant only the operations you need, usually “Push only new package versions”. Leave Environment empty for this workflow.
3. Following NuGet's recommendation, store **`NUGET_USER`** as an organization Actions secret with access to the intended repositories. Use the NuGet profile that created the policies; the packages can belong to a NuGet organization.
4. Pass only that named secret and grant the two permissions shown in the introductory example. Protect your release tags and source.

The username is configuration, **not a publishing credential**. The secret channel keeps its value private and follows NuGet's guidance; the plain `nuget-user` input remains an optional override. Accepting an ordinary input does not expose a value supplied through the secret channel. Consumers can also store the username as an Actions variable and pass `with: { nuget-user: '${{ vars.NUGET_USER }}' }` instead of a secret.

Prefer `secrets: { NUGET_USER: '${{ secrets.NUGET_USER }}' }` over `secrets: inherit`: inheritance makes all eligible caller secrets available to the reusable workflow, while nugetizer needs only this one. Neither choice replaces OIDC authentication or the package-scoped NuGet trust policy.

See [NuGet's policy setup guide](https://learn.microsoft.com/en-us/nuget/nuget-org/trusted-publishing). Credential exchange happens after tests, packing, and archival. Build and publishing share job permissions, so this workflow is for trusted repositories and inputs.

### GitHub permissions

The introductory example enables every stage, so it grants both write permissions. They serve different purposes:

| Permission | Needed for |
|---|---|
| `contents: read` | The `checkout` stage. |
| `contents: write` | The `release` stage: inspecting drafts, creating a release, uploading assets, and publishing it. Includes checkout access. |
| `id-token: write` | The `publish` stage: requesting a GitHub OIDC token for NuGet's credential exchange. It does not grant repository write access or authorize packages by itself. |

With the **composite action in your own job**, grant only what your selected stages need. Validation with checkout needs `contents: read`; NuGet publication without a GitHub release needs `contents: read` and `id-token: write`. Omit OIDC permission when omitting `publish`, and repository write permission when omitting `release`. If checkout is handled elsewhere, its permission requirement belongs to that setup.

The **current reusable workflow** declares `contents: write` and `id-token: write` for its job regardless of the selected stages. Its caller must allow that permission ceiling even for a reduced stage list; selecting fewer stages does not reduce the declared permissions. Use the composite directly for a least-privilege validation job. A reusable workflow can reduce caller permissions, but cannot elevate them.

## Stages and inputs

Stages execute in this fixed order, regardless of their order in the input:

| Stage | Purpose |
|---|---|
| `checkout` | Check out your source. |
| `setup` | Install the SDK from the working-root `global.json`. |
| `test` | Run source-reference tests in Debug. |
| `pack` | Build Release candidate packages once, isolating each project's output before checking for collisions. |
| `integration` | Restore and test those candidates in Release; requires `pack`. |
| `archive` | Upload packages and the ID/version/hash manifest; requires `pack`. |
| `publish` | Obtain an OIDC credential and push verified packages; requires `pack`. |
| `release` | Create a GitHub draft, upload assets, then publish it; requires `publish` and a matching version tag. |

Both entrypoints default to all stages. Use spaces or commas to select a subset. For example, `checkout setup test pack integration archive` validates a candidate without publishing; supply `version` when running off a version tag. A source-test-only run does not require a version.

| Input | Default | When to use it |
|---|---|---|
| `stages` | All stages above | Omit phases you do not need. |
| `working-directory` | `.` | Your project root is below the repository root. |
| `test-target` | Property-based discovery under `tests` | Select source tests explicitly. |
| `integration-target` | Property-based discovery under `tests` | Select package tests explicitly. |
| `pack-target` | Root project/solution | Select the distributable project set. |
| `version` | Tag minus initial `v` | Supply a canonical `major.minor.patch[-prerelease]`; `0.0.0` development versions cannot be published. |
| `nuget-user` | Ambient `NUGET_USER` | Override the policy creator's profile. |

Runner selection follows `global.json`; SDK 11+ also supports `DOTNET_TEST_RUNNER`. The native test CLI controls test results and failures. Nugetizer supports C# projects and `.sln`/`.slnx` solutions.

## Testing locally

Keep a configuration-derived local version in shared `Directory.Build.props`:

```xml
<PropertyGroup>
  <PackageUnderTestVersion Condition="'$(PackageUnderTestVersion)' == ''">0.0.0-$(Configuration.ToLowerInvariant())</PackageUnderTestVersion>
  <Version>$(PackageUnderTestVersion)</Version>
</PropertyGroup>
```

Debug uses `0.0.0-debug`; Release uses `0.0.0-release`. Command-line candidate versions take precedence during nugetizer's pack stage. Keep integration references exact and avoid a separate fixed `PackageVersion` that disagrees with these settings.

Source tests run normally. For package integration, **pack first**, then supply the local feed. From the repository root, using native MTP:

```powershell
dotnet pack src/Your.Package/Your.Package.csproj -c Release -o artifacts/package/release
dotnet test --project tests/Your.Package.IntegrationTests/Your.Package.IntegrationTests.csproj -c Release -p:RestoreAdditionalProjectSources="$PWD/artifacts/package/release"
```

For VSTest, omit `--project`. Pack required sibling packages into that feed too. Plain `dotnet test` does not create package dependencies; refresh reused local packages/caches when necessary. The pipeline supplies its own isolation. See the [fixture](tests/fixtures) for working source-reference and package-reference examples.

## Workflow or composite action?

The reusable workflow supplies the Ubuntu job and calls `podnet-dev/pod-nugetizer@v2` normally. The composite owns every pipeline step, including checkout. The inner action follows moving `v2` even when you pin the reusable workflow itself.

For a custom job, invoke the composite directly, pass `NUGET_USER` through the environment, and omit `checkout` if source is already checked out. Workspace-local actions must omit checkout to preserve their files. Custom runtime/workload setup can precede the action; omit `setup` when you've prepared the toolchain. Other runners need your own validation.

## If publication partially fails

NuGet publication and GitHub releases are not a transaction. Existing GitHub releases/drafts are checked before login/push and again before creation, but concurrent changes can still intervene. Duplicate NuGet versions remain errors; release assets are not silently overwritten.

1. Download the run's archived packages and manifest. Verify remote package contents and source provenance; NuGet repository signing can change downloaded archive bytes. Stop on conflicts—versions cannot be reused.
2. Publish only missing packages with the reviewed artifacts and an authorized credential. Check symbols separately rather than blindly rerunning the full pipeline.
3. For a draft from this run, inspect its assets and upload only missing files with `gh release upload`. Resolve conflicting assets deliberately.
4. Publish the complete draft with `gh release edit <tag> --draft=false --repo <owner/repo>`, preserving its prerelease status. An unrelated draft needs its owner's approval; an incorrect published immutable release needs a new-release plan.

If archival was omitted, preserve the original staged files before recovery. See [migration notes](MIGRATION.md) for v1 consumers.

## Advanced usage

Start with the defaults; add overrides only where your repository needs them:

```yaml
on: { push: { tags: ['v*'] } }
jobs:
  publish:
    uses: podnet-dev/pod-nugetizer/.github/workflows/default.yml@v2
    secrets:
      NUGET_USER: ${{ secrets.NUGET_USER }}  # Pass only the profile setting, not every caller secret.
    permissions: { contents: write, id-token: write }
    with:
      stages: checkout setup test pack integration archive publish release
      working-directory: packages          # global.json, solution and tests live here.
      test-target: tests/Example.Tests/Example.Tests.csproj # Source-test phase only.
      integration-target: tests/Example.IntegrationTests/Example.IntegrationTests.csproj # Marked package tests.
      pack-target: Example.slnx             # All required packages; test projects are nonpackable.
      version: 2.3.0                       # Optional; must match v2.3.0 when creating its release.
      nuget-user: example-publisher         # Optional plain-input override of the named secret.
```