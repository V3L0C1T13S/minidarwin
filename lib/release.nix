# The release this tree becomes when it is tagged. See docs/rootfs-spec.md.
#
# `sequence` only ever goes up. A consumer that has accepted release N refuses
# an older one as an update (rollback protection), and the release workflow
# refuses a tag whose sequence does not exceed the last published release's.
# Bump it in the commit you tag.
{
  sequence = 2;
}
