# Brickstrap search path
The brickstrap search path mechanism provides a way for configuration to be split over re-usable components that may be
included or excluded based on parameters passed at build time. This document covers:
 - How brickstrap looks up 'paths' inside a configuration directory hierarchy
 - What variables influence this behaviour, and what these represent
 - How this mechanism is used for overriding specific bits and pieces of configuration, depending on parameters at build time.
 - How a configuration directory hierarchy (a project) may be structured to take full advantage of this.
 - How you can debug your configuration directory structure to make sure the 'right' configuration is derived from each combination of parameters you wish to support.

## Summary
The table below summarises how the search path mechanism works and what variables control it:

| Priority  | Variable     | Prefix                 | Disable validation with      |
|----------:|:-------------|:-----------------------|:-----------------------------|
| 4         | `BR_VARIANT` | `variant/$BR_VARIANT`  | `BR_IGNORE_INVALID_VARIANT`  |
| 3         | `BR_BOARD`   | `board/$BR_BOARD`      | `BR_IGNORE_INVALID_BOARD`    |
| 2         | `BR_ARCH`    | `arch/$BR_ARCH`        | `BR_IGNORE_INVALID_ARCH`     |
| 1         | `BR_DISTRO`  | `distro/$BR_DISTRO`    | `BR_IGNORE_INVALID_DISTRO`   |
| 0         | base path    | (none)                 | (not applicable)             |

The various variables may be combined, which yields a combined prefix, starting with the highest priority variable and ending with the lowest one, having a priority of the sum of its parts.
For example, `BR_DISTRO` may be combined with `BR_ARCH` and `BR_VARIANT` to produce a prefix of `variant/$BR_VARIANT/arch/$BR_ARCH/distro/$BR_DISTRO` with a priority of `(4 + 2 + 1) = 7`.
All prefixes are interpreted relative to the root of the entire configuration directory hierarchy which is represented by the `BR_PROJECT` variable.

Paths are located on the search path by trying every applicable prefix of higher priority before falling back to a lower priority one, until an applicable path is found.
As a last resort, the search path mechanism will fall back to `BR_PROJECT`, i.e accept an item relative to the project root itself if it is available.

Search path variables are validated during start up of brickstrap, however by setting the corresponding `BR_IGNORE_INVALID_*` variable validation may be selectively disabled.
This applies also to `BR_PROJECT`.

The variables may either be set as environment variables prior to invoking brickstrap or passed on the brickstrap commandline using these switches:

|Variable       | Validated switch  | Alternative switch  |
|:--------------|:------------------|:--------------------|
| `BR_VARIANT`  | `-v`              | `-V`                |
| `BR_BOARD`    | `-b`              | `-B`                |
| `BR_ARCH`     | `-a`              | `-A`                |
| `BR_DISTRO`   | `-d`              | `-D`                |
| `BR_PROJECT`  | `-p`              | `-P`                |

The alternative switches are equivalent to setting the corresponding `BR_IGNORE_INVALID_*` variable at the same time, disabling validation of the configurated variable during brickstrap start up.

Functions are provided for user code (such as hooks) to query the search path for a given base path, i.e. to resolve a base path to a single item or a list of applicable candidates.
See the 'Functions' section for details. User code *should not* attempt to construct paths manually, and configuration *should* be coded to refer to relative paths.

Various debug tools are available which may be used to query a project directory using brickstrap search path mechanism for files and learn which items brickstrap returns for any particular
combination of variable values.

## Rationale
Brickstrap uses a concept of 'layering' by which various logically separate directory trees are overlaid on top of each other.
The purpose of this mechanism is to enable greater reuse of common configuration components or in other words:
to let you repurpose a project configuration for different environments.

Brickstrap supports four different variables in addition to the project variable `BR_PROJECT` to describe a build environment and derive its complete configuration.
These four variables are meant solely as descriptive identifiers by which configuration may be partitioned in various sub directories during development and logically 're-assembled' during build.
*Nota bene*: brickstrap doesn't perform extensive validation of the value for such variables and what validation is performed may be turned off (for development/debug purposes).
Ultimately, to brickstrap the values of these variables are just arbitrary strings.

 * Variant (`BR_VARIANT`): describes a build variant such as "minimal" or "full"
 * Board (`BR_BOARD`): describes hardware supported by the project, e.g. "BeagleBone Black" or "my laptop"
 * Architecture (`BR_ARCH`): describes the system 'architecture' which will be supported by binaries in the built image, e.g. "ARMv7" or "x86_64"
   Typically this corresponds to the 'architecture' of the Debian repositories used by the build, e.g. "armel" or "amd64".
 * Distribution  (`BR_DISTRO`): describes the distribution which packages that are downloaded and installed in the image are part of.
   Typically this corresponds to a code name like "jessie" or "sparkly-unicorn"

Depending on the contents of the project root hierarchy, these variables can be combined to express more complicated scenario's such as:
"build a minimal image (`minimal`) for Raspberry Pi 2 Model B (`rpi2`) using the Debian Jessie distribution (`jessie`)".

This is an 'opt-in' scheme, configuration directories *may* selectively opt in to specific variables by adopting the necessary directory layout conventions (discussed below) but projects
are not required to do so. The search path scheme is implemented in such a way that it works also with simple project structures that are entirely unaware of it.

Still it is recommended to adopt the scheme if you wish to support building multiple different versions of an image for the same project. The benefits to you as a maintainer are:
 * Reduce maintenance workload by sharing common configuration components
 * Handle hardware, distribution or architecture dependent 'quirks' in your configuration more easily.
 * Convenience: brickstrap supports setting these variables as part of the brickstrap commandline.
 * Delegation and partitioning: separate 'concerns' expressed in the configuration are relegated to their own 'parts' of the project hierarchy.

The benefits for end-users of a brickstrap project (configuration) are:
 * Consistency: brickstrap offers a simple and consistent way to access these features in any project that uses the convention.
 * Debugging: if something goes wrong, it is easier to pinpoint 'what' part of the configuration is at fault simply by eliminating variables.



