# cmdblish (CoMmenDaBLISH)

Tool of Configuration Management DB (reverse engineering type) for files on server VM. 

## Getting Started

    git clone https://github.com/frisky-gh/cmdblish.git
    cd cmdblish
    for i in conf/*.example ; do cp $i ${i%.example} ; done
    ./bin/cmdblevidence run `date +%Y-%m-%d` TARGETHOSTS ...

## Usage

    usage: % ./bin/cmdblevidence SUBCOMMAND ...
    
    SUBCOMMAND
        get_fileinfo        HOSTNAME@TIMEID
        get_pkginfo_os      HOSTNAME@TIMEID
        get_pkginfo_git     HOSTNAME@TIMEID
        fix_pkginfo_os      HOSTNAME@TIMEID
        extract_pkginfo_userdefined HOSTNAME@TIMEID
        extract_volatiles   HOSTNAME@TIMEID
        extract_settings    HOSTNAME@TIMEID
        extract_unmanaged   HOSTNAME@TIMEID
        get_settingcontents HOSTNAME@TIMEID
        wrapup              HOSTNAME@TIMEID
        run         TIMEID HOSTNAME [HOSTNAME ...]
        run_extract TIMEID HOSTNAME [HOSTNAME ...]

## Status Files

`./status` directory contains all evidences of server file configurations
captured by `cmdblish`.


- pkgversions.tsv
- settingcontents.tsv
- unmanaged.tsv

- pkgnames.tsv
- settings.tsv

- pkginfo_git.tsv
- pkginfo_userdefined.tsv

### `pkginfo_git.tsv` File

In `pkginfo_git.tsv`, `VERSION` format is the following:

    GIT_COMMITID . MODIFIED_FILENAMES_HASH . MODIFIED_FILECONTENTS_HASH

### `pkginfo_userdefined.tsv` File

In `pkginfo_userdefined.tsv`, `VERSION` format is the following:

    MODULE_FILENAMES_HASH . MODULE_FILEATTRS_HASH

