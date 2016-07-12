# Create a release notes template file.

cat > $(br_report_dir)/$(br_image_basename)-release-notes.md << EOF
Release notes for $(br_image_name)
==============================================

Changes from previous version
-----------------------------


Known issues
------------


Built using
-----------
* $(lsb_release -ds)
* $(dpkg-query --show brickstrap | sed 's/\t/ /')
* $(dpkg-query --show libguestfs-tools | sed 's/\t/ /')
* $(dpkg-query --show multistrap | sed 's/\t/ /')
* $(dpkg-query --show qemu-user-static | sed 's/\t/ /')

Included Packages
-----------------

\`\`\`
$(br_chroot dpkg -l)
\`\`\`
EOF

if [ "$TRAVIS" == "true" ]; then

cat > $(br_report_dir)/bintray.json << EOF
{
    "package": {
        "name": "$BR_PROJECT",
        "repo": "nightly",
        "subject": "ev3dev",
        "desc": "SD card images for testing",
        "website_url": "www.ev3dev.org",
        "issue_tracker_url": "https://github.com/ev3dev/ev3dev/issues",
        "vcs_url": "https://github.com/ev3dev/ev3dev.git",
        "github_use_tag_release_notes": false,
        "licenses": ["GPL-2.0"],
        "public_download_numbers": true,
        "public_stats": true
    },

    "version": {
        "name": "$(date --iso-8601)",
        "desc": "Unsupported image for testing.",
        "released": "$(date --iso-8601=seconds)",
        "gpgSign": false
    },

    "files":
        [
        {"includePattern": "$(br_image_dir)/(.*\.xz)", "uploadPattern": "\$1"}
        ],
    "publish": true
}
EOF

fi
