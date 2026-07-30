# Releasing this project

The routine, start to finish. Settings live in [build/build.json](build/build.json); the
commands below come from the build kit in [build/](build/).

## One-time setup

- **CommandBox** installed (`box version`).
- **GitHub CLI** signed in, if you publish GitHub Releases: `gh auth login`.
- **ForgeBox** signed in, if you publish there: `box forgebox login`.
- A test server you can start, unless `runTests` is off in build.json.

Check all of it at once:

```
box run-script release:check
```

## The routine

### 1. Write your notes as you work

Put changes under `## [Unreleased]` in the changelog. Write them for the people who use the
project, because this text becomes the release notes.

### 2. Test on every engine

```
box run-script test:engines
```

Runs the whole suite on each engine in turn. It takes a while, so it is a separate step. Skip
it if your project only supports one engine.

### 3. Raise the version

```
box run-script bump:patch     # bug fixes           1.0.0 -> 1.0.1
box run-script bump:minor     # new features        1.0.0 -> 1.1.0
box run-script bump:major     # breaking changes    1.0.0 -> 2.0.0
```

This raises the version in box.json and moves your `[Unreleased]` notes into a dated section.
It does not commit anything.

Add `:dryRun=true` to any of these to see what would change without writing anything.

**Your notes are required.** If `[Unreleased]` is empty, nothing happens at all: no version
change and no changelog change. The dated section becomes your release notes on GitHub, so an
empty one would ship a release nobody can interpret. Write a line first, even just
`- Maintenance release`.

**Releasing 1.0.0 for the first time?** box.json probably already says 1.0.0, and raising it
would skip that number. Date the notes without changing the version:

```
box task run taskFile=build/Bump.cfc :level=none
```

#### Alphas and betas

Version numbers follow SemVer, where `1.2.0-beta.3` comes **before** `1.2.0`. These commands
follow the same rule, so finishing a beta lands on the version it was leading up to rather than
stepping past it.

```
box run-script bump:beta          # start one:  1.1.0 -> 1.2.0-beta.1
box run-script bump:alpha         # the same, labelled alpha
box run-script bump:prerelease    # step it on: 1.2.0-beta.1 -> 1.2.0-beta.2
box run-script bump:patch         # finish it:  1.2.0-beta.2 -> 1.2.0
```

`bump:beta` and `bump:alpha` start a prerelease of the next **minor** version. For a prerelease
of the next patch or major instead, name the level yourself:

```
box task run taskFile=build/Bump.cfc :level=prepatch     # 1.1.0 -> 1.1.1-beta.1
box task run taskFile=build/Bump.cfc :level=preminor     # 1.1.0 -> 1.2.0-beta.1
box task run taskFile=build/Bump.cfc :level=premajor     # 1.1.0 -> 2.0.0-beta.1
```

Add `:preid=rc` to use a different label. Switching label restarts the count, so
`1.2.0-alpha.7` with `:preid=beta` becomes `1.2.0-beta.1`.

A prerelease is flagged as one on GitHub automatically, because the version contains a hyphen.

Every level, for reference:

| Level | What it does |
| --- | --- |
| `patch`, `minor`, `major` | Raise the version. On a prerelease, settle on the version it was leading up to. |
| `prerelease` | Step an existing prerelease forward, `beta.3` to `beta.4`. |
| `prepatch`, `preminor`, `premajor` | Start a prerelease. Uses `:preid=beta` unless you say otherwise. |
| `none` | Keep the version and just date the changelog. |

### 4. Check and commit

```
git diff
git commit -am "Release 1.0.1"
git push origin main
```

### 5. Rehearse (recommended the first few times)

```
box run-script release:dryrun
```

Runs the checks and the full build, then prints exactly what it would publish, tag, and push.
Nothing leaves your machine.

### 6. Release

Start a test server first, unless `runTests` is off:

```
box run-script release
```

That runs the checks, lines up with the remote, runs the tests, builds and verifies the
package, publishes it, tags the version, and creates the GitHub Release.

## Just built a hotfix and already ran the tests?

```
box run-script release:hotfix
```

Same as `release`, but skips the test suite and says so loudly.

## If something fails partway

Everything that can stop a release happens **before** anything is published. If a step fails
**after** publishing, do not run the release again: the version is already out, so the checks
will refuse. The failure message prints the exact commands to finish by hand.

To finish only the tag and GitHub Release:

```
box task run taskFile=build/Release.cfc target=github :version=1.0.1
```

## Common problems

| Message | What it means |
| --- | --- |
| `You have uncommitted changes` | Commit or stash first. The release refuses so the forced checkout cannot throw work away. |
| `No answer from the test server` | Start your server, or set `runTests` to false in build.json. |
| `Could not find the GitHub CLI` | Install it, then **open a new terminal**. A terminal keeps the PATH it started with. |
| `Permission denied (publickey)` | git cannot sign in to your remote. Add your SSH key on GitHub, or switch the remote to HTTPS. |
| `has no "## [1.0.1]" section` | Run a `bump:` command to move your notes into a dated section. |
| `The "## [Unreleased]" section is empty` | Write your release notes first. Nothing was changed. |
| `is not a prerelease, so there is nothing to step forward` | Use `bump:beta` to start one, not `bump:prerelease`. |
| `Tag v1.0.1 already exists` | That version is already released. Raise the version. |
