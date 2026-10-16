# How zstaller writes MSI packages

An MSI file is a Windows Installer database stored in an OLE compound file.
zstaller writes it directly in Zig, in four layers:

| Layer | Source | Specification |
| --- | --- | --- |
| Compound file (CFB v3, 512-byte sectors) | [`cfb.zig`](../src/platforms/windows/msi/cfb.zig) | [MS-CFB] |
| Installer database (tables, string pool, summary information) | [`database.zig`](../src/platforms/windows/msi/database.zig) | Windows Installer SDK, [MS-OLEPS] |
| Product layout (which rows go in which tables) | [`package.zig`](../src/platforms/windows/msi/package.zig) | Windows Installer SDK |
| Embedded cabinet (MSZIP) | [`cab.zig`](../src/platforms/windows/msi/cab.zig) | [MS-CAB], [MS-MCI] |

## Compound file

Every stream is a direct child of the root storage. Streams under 4096 bytes
go to the mini stream; the rest use regular sectors. The FAT grows through
DIFAT sectors when needed, and directory entries form a balanced red-black
tree ordered by name length then upper-cased name, as Windows requires. The
root entry carries the Windows Installer CLSID
`{000C1084-0000-0000-C000-000000000046}`.

## Database

- **Stream names.** Table and stream names are compressed into the private
  Unicode range: pairs of characters from the 64-character alphabet map to
  `0x3800 + a + (b << 6)`, single characters to `0x4800 + a`, and table
  streams are prefixed with `0x4840`.
- **String pool.** `_StringPool` holds the codepage (1252) and a
  (length, refcount) pair per string; `_StringData` holds the bytes. String
  ids are assigned in sorted order so output is deterministic.
- **Tables.** Each table is a column-major stream of rows sorted by primary
  key. Strings and 2-byte integers are 16-bit (strings are ids into the
  pool; integers are stored with the sign bit flipped), 4-byte integers likewise,
  and `0` means null.
- **Catalog.** `_Tables` and `_Columns` describe every table, with column
  type bits for string length, integer size, nullable, key and
  localizable.
- **Summary information.** `\x05SummaryInformation` is an OLE property set
  with the codepage, title, subject, author, template (`x64;1033` or
  `Arm64;1033`), package code, page count (schema 500), word count
  (compressed, per-machine) and a fixed timestamp.

## Product layout

Tables written: `Property`, `Directory`, `Component`, `File`,
`FeatureComponents`, `Registry`, `Environment`, `Feature`, `Media`, `Icon`,
`Shortcut`, `CreateFolder`, `MsiLockPermissionsEx`, `Upgrade`,
`LaunchCondition`, `AppSearch`, `RegLocator`, `CustomAction` (only with hooks), `InstallExecuteSequence`,
`InstallUISequence`. The icon (a binary column of the `Icon` table) and the
cabinet are stored as separate streams.

- One feature, `Complete`; one component per file, so each file has a
  stable key path. Component GUIDs are UUIDv5 values derived from the
  upgrade code, platform and file path, so they stay stable across
  versions as the component rules require.
- `INSTALLDIR` is `<root>\<install dir>`, where the root is
  `ProgramFiles64Folder`, `CommonAppDataFolder` or `WindowsVolume`
  (`install_root`). A nested install dir (`Acme\Widget`) gets one
  `Directory` row per folder. 8.3 short names are generated for every
  directory and file.
- **Permissions.** `CreateFolder` and `MsiLockPermissionsEx` give
  `INSTALLDIR` an owner of Administrators and a protected DACL: SYSTEM and
  Administrators full control, Users and app packages read and execute.
  Outside Program Files the `INSTALLPARENT` folders of a nested install
  dir get the same, so users cannot rename them. Files inherit from
  `INSTALLDIR`. (`MsiLockPermissionsEx` needs Windows Installer 5.0, which
  every supported Windows has.)
- **Per user** (`scope = .user`): no `ALLUSERS` property, so Windows
  Installer installs for the current user; word count 10 (no elevation
  needed); `INSTALLDIR` under `LocalAppDataFolder\Programs`; registry
  key paths in `HKEY_CURRENT_USER`; the PATH entry `=-Path` in the
  user's environment; no folder locking; hooks without the
  no-impersonate flag, so they run as the user.
- **EXE installation.** `AppSearch` reads `InstallLocation` from the
  EXE installer's `Uninstall\zstaller.<name>` key (64-bit view) into
  `EXEINSTALLDIR`, and the launch condition `Installed OR NOT
  EXEINSTALLDIR` refuses a new install while it is set. Repairing and
  removing an installed MSI are not affected.
- **Hooks.** `after_install` and `before_uninstall` are `CustomAction`
  rows of type 3090: 18 (run an installed `.exe`, `Source` is its `File`
  key, `Target` its arguments with `[`, `]`, `{` and `}` escaped as
  `[\x]`), deferred (0x400) and no-impersonate (0x800), so they run in
  the install script as LocalSystem. `ZstallerAfterInstall` is sequenced
  at 6500, after the files and registration, with condition
  `NOT REMOVE~="ALL"`; a non-zero exit code fails the install and rolls
  it back. `ZstallerBeforeUninstall` (3154: adds 0x40, ignore the exit
  code) runs at 3100, before `RemoveShortcuts` and `RemoveFiles`, with
  condition `REMOVE~="ALL" AND NOT UPGRADINGPRODUCTCODE`, so the removal
  of an old version during a major upgrade does not run it.
- The cabinet is stored as stream `product.cab` and referenced from the
  `Media` table as `#product.cab`.
- **Upgrades.** The product code is derived from the upgrade code, the
  full package version (pre-release and build included) and the platform,
  so `1.0.0-rc.1` and `1.0.0` are different products with the same
  ProductVersion. The `Upgrade` table finds older versions and other
  products with the same ProductVersion (`OLDERVERSIONFOUND`, with
  `VersionMaxInclusive`; removed by `RemoveExistingProducts` right after
  `InstallValidate`) and newer ones (`NEWERVERSIONFOUND`, which a launch
  condition turns into a clear error).
- **PATH.** With `add_to_path = .optional` or `.always`, a component adds
  `[INSTALLDIR]` to the end of the system `Path` (`=-*Path`,
  `[~];[INSTALLDIR]`), removed on uninstall. For `.optional` it is
  conditioned on the public `ADDTOPATH` property, default `1`.
- **Shortcuts.** The Start Menu shortcut belongs to the component of the
  file it opens. The desktop shortcut has its own component, keyed by a
  registry value, so that `.optional` can condition it on the public
  `DESKTOPSHORTCUT` property (default `0`).
- An Apps & Features icon (`ARPPRODUCTICON`) is added when `icon` is set.

## Verification

Unit tests read the generated files back with a minimal CFB reader and
cabinet extractor. When available, `msiinfo` from msitools also validates
the database. CI installs and uninstalls the sample MSI with
`msiexec /qn` on Windows.

[MS-CFB]: https://learn.microsoft.com/openspecs/windows_protocols/ms-cfb/
[MS-OLEPS]: https://learn.microsoft.com/openspecs/windows_protocols/ms-oleps/
[MS-CAB]: https://learn.microsoft.com/previous-versions/bb417343(v=msdn.10)
[MS-MCI]: https://learn.microsoft.com/openspecs/exchange_server_protocols/ms-mci/
