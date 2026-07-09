# Guix Channel Utils

```scheme
(channel
 (name 'channel-utils)
 (url "https://github.com/jack-faller/guix-channel-utils")
 (introduction
  (make-channel-introduction
   "657d9af9cf1729a288a9c25f014523ff34ac656f"
   (openpgp-fingerprint
    "D97A 5464 A392 0366 1ED9  5C07 A043 7B42 9C10 4C61"))))
```

## Library Functions

The module `(guix channels utils)` provides `git-toplevel`, `relative-file` and `git-source-file?`.
The intended usage is to have a single repository that contains both the source code for a package, and a channel that contains its package definition.
This makes it easier to maintain package definitions for a single project and makes them more discoverable to users.
A repository with this structure can be seen at [github.com/jack-faller/miny](https://github.com/jack-faller/miny/tree/changes).

The core concept is that a package is provided in `guix/xyz/jackfaller/miny`, where `guix/` is the channel directory and `xyz/jackfaller/miny` is an RDNS for the package name.
In the corresponding file, the definition looks like this:
```scheme
...
(package
  ...
  (source (relative-file "../../.." name #:recursive? #t #:select? git-source-file?))
  ...)
```
Using `relative-file` as the source allows the package to reach up out of the channel and grab the source files in the root of the repository.
With `local-file`, this would fail on some builds as the current file name isn't exposed properly, but the `relative-file` macro hacks around that restriction.
Then using `git-source-file?` as `#:select?` will only allow non-ignored files from the current repository and discard the `.git` folder, making build hashes more repeatable and ensuring cached build artefacts aren't used.

The ultimate effect of this is that the channel can be used in the working tree like so:
```bash
$ guix build -Lguix miny
```
And with any other commands using the `-L` flag to add the channel directory to the load path.
The channel functions both locally and remotely, with no need for users to copy paste package definitions from `guix.scm`.

I believe in terms of functionality, this is one of the best ways to provide Guix package definitions for an individual project.
The main thing stopping it is the annoyance of creating new channels, which can be circumvented with the helper commands provided in the `channel-utils` package.

## Guix Channel Helper Program

A helper program `guix channel` is packaged in this channel, providing a quick way to initialise a channel and add keys to it.
It has the subcommands `init`, `add`, `set`, `get`, and `remove`.
These can each be used to update the to update the information in a channel.
Supported fields to initialise/update are authorized keys, the URL, the channel directory, channel dependencies, and the keyring branch name.
`Init` will only work in directories which aren't a part of a channel, `add` will not overwrite values, `set` will overwrite values.

Additionally `guix channel export` will output the Scheme code for instancing a channel and with an introduction.
