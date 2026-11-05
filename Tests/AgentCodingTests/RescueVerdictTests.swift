import Foundation
import Testing
@testable import bromure_ac

// The deep repair's verdict on its rescue's run: repaired only when the
// script ran to its end (rc=0) and said something about every image.

@Suite("Rescue verdict")
struct RescueVerdictTests {
    let images = ["disk.img", "data.img"]

    @Test("each image checked and rc=0 is a repair; a data disk with no ext4 passes")
    func repaired() {
        #expect(KubeClusterEngine.rescueRepaired("fsck: disk.img loop0p2 exit=1\nfsck: data.img loop1 exit=0\nrc=0\n", images: images, mayLackExt4: ["data.img"]))
        #expect(KubeClusterEngine.rescueRepaired("fsck: disk.img loop0p2 exit=0\nfsck: data.img no ext4\nrc=0", images: images, mayLackExt4: ["data.img"]))
    }

    @Test("nothing reported, an image unreported, errors left, a missing image, a set -u abort, no rc, the root disk with no ext4, a blkid failure: not a repair")
    func notRepaired() {
        for out in ["rc=0\n",
                    "fsck: disk.img loop0p2 exit=1\nrc=0\n",
                    "fsck: disk.img loop0p2 exit=4\nfsck: data.img loop1 exit=0\nrc=4\n",
                    "fsck: disk.img missing\nfsck: data.img loop1 exit=0\nrc=8\n",
                    "/tmp/bromure-rescue-fsck.sh: line 9: x: unbound variable\nrc=1\n",
                    "fsck: disk.img loop0p2 exit=0\nfsck: data.img loop1 exit=0\n",
                    "fsck: disk.img no ext4\nfsck: data.img loop1 exit=0\nrc=0\n",
                    "fsck: disk.img loop0p2 blkid failed (127)\nfsck: data.img loop1 exit=0\nrc=8\n"] {
            #expect(!KubeClusterEngine.rescueRepaired(out, images: images, mayLackExt4: ["data.img"]), "\(out)")
        }
    }
}
