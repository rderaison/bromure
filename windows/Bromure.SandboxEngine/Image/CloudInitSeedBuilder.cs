using System.Text;

namespace Bromure.SandboxEngine.Image;

/// <summary>
/// Pure-C# ISO9660 (no Joliet, no Rock Ridge, no extensions) generator
/// that produces a cloud-init <c>nocloud</c> seed image. Writes a small
/// CD-ROM containing two files at the volume root:
///
/// <list type="bullet">
///   <item><c>user-data</c> — the bash userdata cloud-init runs.</item>
///   <item><c>meta-data</c> — instance-id + local hostname.</item>
/// </list>
///
/// <para><b>Why not shell out to <c>genisoimage</c> / <c>mkisofs</c>?</b>
/// Adding either as a runtime dep means an extra installer payload and
/// path resolution on user machines. Cloud-init's nocloud format only
/// requires ISO9660 with a volume label of <c>cidata</c>, two files
/// each &lt; ~64 KB, no extensions. ISO9660 in that constrained
/// configuration is a few hundred bytes of layout — easy to emit
/// directly.</para>
///
/// <para>References used while writing: ECMA-119 (ISO9660 spec) §6 + §7.
/// The format is byte-exact: PVD at LBA 16, terminator at LBA 17, root
/// path table at LBA 18-19, root directory record at LBA 20, file
/// contents from LBA 21 onward, all on 2048-byte sectors.</para>
/// </summary>
public static class CloudInitSeedBuilder
{
    private const int SectorSize = 2048;

    public static void WriteSeed(string outputPath, string userData, string metaData)
    {
        var entries = new (string Name, byte[] Bytes)[]
        {
            ("meta-data", Encoding.UTF8.GetBytes(metaData)),
            ("user-data", Encoding.UTF8.GetBytes(userData)),
        };
        WriteIso(outputPath, entries, volumeLabel: "cidata");
    }

    /// <summary>
    /// Generic single-file ISO emit — used by the Alpine-bake flow to
    /// drop <c>setup.sh</c> into the installer guest as <c>/dev/sr0</c>.
    /// Volume label can be anything; kept short so cloud-init's
    /// "cidata"-only matcher doesn't false-positive against our ISO.
    /// </summary>
    public static void WriteScriptIso(string outputPath, string fileName, byte[] contents,
        string volumeLabel = "BROMUREISO")
    {
        WriteIso(outputPath, new (string, byte[])[] { (fileName, contents) }, volumeLabel);
    }

    /// <summary>
    /// Multi-file variant — used by <see cref="SessionMetadataIso"/> at
    /// session-start to bundle env vars + dotfiles into a single small
    /// CD-ROM the guest mounts at <c>/mnt/bromure-meta</c>.
    /// </summary>
    public static void WriteFilesIso(string outputPath,
        IEnumerable<(string Name, byte[] Bytes)> files, string volumeLabel)
    {
        WriteIso(outputPath, files.ToArray(), volumeLabel);
    }

    private static void WriteIso(string outputPath,
        (string Name, byte[] Bytes)[] entries, string volumeLabel)
    {
        // Lay out:
        //   Sectors 0–15  : system area (zeros — stage-1 boot space).
        //   Sector 16     : Primary Volume Descriptor.
        //   Sector 17     : Volume Descriptor Set Terminator.
        //   Sectors 18-19 : path tables (L + M endian).
        //   Sector 20     : root directory.
        //   Sector 21+    : file contents, each 2048-byte aligned.
        var fileLbas = new int[entries.Length];
        var fileSizes = new int[entries.Length];
        var fileExtents = new int[entries.Length];
        var nextLba = 21;
        for (var i = 0; i < entries.Length; i++)
        {
            fileLbas[i] = nextLba;
            fileSizes[i] = entries[i].Bytes.Length;
            fileExtents[i] = (entries[i].Bytes.Length + SectorSize - 1) / SectorSize;
            nextLba += Math.Max(fileExtents[i], 1);
        }
        var totalSectors = nextLba;

        var image = new byte[totalSectors * SectorSize];

        WritePrimaryVolumeDescriptor(image, 16, totalSectors, volumeLabel);
        WriteVolumeDescriptorTerminator(image, 17);
        WritePathTable(image, 18, littleEndian: true);
        WritePathTable(image, 19, littleEndian: false);
        WriteRootDirectory(image, 20, entries, fileLbas, fileSizes);

        for (var i = 0; i < entries.Length; i++)
        {
            Array.Copy(entries[i].Bytes, 0, image, fileLbas[i] * SectorSize, entries[i].Bytes.Length);
        }

        File.WriteAllBytes(outputPath, image);
    }

    private static void WritePrimaryVolumeDescriptor(byte[] image, int lba, int totalSectors, string volumeLabel)
    {
        var off = lba * SectorSize;
        image[off + 0] = 0x01;                                  // type = primary
        WriteAscii(image, off + 1, "CD001", 5);                 // identifier
        image[off + 6] = 0x01;                                  // version
        // 7: unused (1 byte)
        WriteAscii(image, off + 8, "BROMURE_AC", 32);           // system identifier (A-chars padded)
        WriteAscii(image, off + 40, volumeLabel, 32);           // volume identifier
        // 72-79: unused
        WriteBothEndianU32(image, off + 80, totalSectors);      // volume space size
        // 88-119: unused (escape sequences)
        WriteBothEndianU16(image, off + 120, 1);                // volume set size
        WriteBothEndianU16(image, off + 124, 1);                // volume sequence number
        WriteBothEndianU16(image, off + 128, SectorSize);       // logical block size
        WriteBothEndianU32(image, off + 132, 10);               // path table size in bytes
        WriteUInt32LE(image, off + 140, 18);                    // type-L path table location
        WriteUInt32LE(image, off + 144, 0);                     // optional type-L
        WriteUInt32BE(image, off + 148, 19);                    // type-M path table location
        WriteUInt32BE(image, off + 152, 0);                     // optional type-M

        // Root directory record (34 bytes at offset 156).
        WriteDirectoryRecord(image, off + 156, lba: 20,
            dataLen: SectorSize, name: "\0", isDir: true);

        WriteAscii(image, off + 190, "BROMURE_AC", 128);        // volume set ident
        WriteAscii(image, off + 318, "BROMURE_AC", 128);        // publisher
        WriteAscii(image, off + 446, "", 128);                  // data preparer
        WriteAscii(image, off + 574, "", 128);                  // application
        WriteAscii(image, off + 702, "", 37);                   // copyright file
        WriteAscii(image, off + 739, "", 37);                   // abstract file
        WriteAscii(image, off + 776, "", 37);                   // bibliographic file

        var ts = "2025010100000000";  // YYYYMMDDhhmmsscc — fixed for reproducibility
        WriteAscii(image, off + 813, ts, 17);                   // creation time
        WriteAscii(image, off + 830, ts, 17);                   // modification time
        WriteAscii(image, off + 847, "0000000000000000", 17);   // expiration time (never)
        WriteAscii(image, off + 864, ts, 17);                   // effective time
        image[off + 881] = 0x01;                                // file structure version
    }

    private static void WriteVolumeDescriptorTerminator(byte[] image, int lba)
    {
        var off = lba * SectorSize;
        image[off] = 0xFF;
        WriteAscii(image, off + 1, "CD001", 5);
        image[off + 6] = 0x01;
    }

    /// <summary>
    /// Path table with a single entry pointing at the root directory.
    /// L-type uses little-endian extent values; M-type uses big-endian.
    /// </summary>
    private static void WritePathTable(byte[] image, int lba, bool littleEndian)
    {
        var off = lba * SectorSize;
        image[off + 0] = 1;        // directory identifier length (1 = root special)
        image[off + 1] = 0;        // ext attr length
        if (littleEndian) WriteUInt32LE(image, off + 2, 20);
        else WriteUInt32BE(image, off + 2, 20);
        if (littleEndian) WriteUInt16LE(image, off + 6, 1);
        else WriteUInt16BE(image, off + 6, 1);
        image[off + 8] = 0;        // root identifier byte
        image[off + 9] = 0;        // padding
    }

    private static void WriteRootDirectory(
        byte[] image, int lba,
        (string Name, byte[] Bytes)[] entries,
        int[] fileLbas,
        int[] fileSizes)
    {
        var off = lba * SectorSize;
        var cursor = 0;

        // "." entry — 34 bytes, identifier = 0x00.
        cursor += WriteDirectoryRecord(image, off + cursor, lba,
            dataLen: SectorSize, name: "\0", isDir: true);
        // ".." entry — 34 bytes, identifier = 0x01.
        cursor += WriteDirectoryRecord(image, off + cursor, lba,
            dataLen: SectorSize, name: "", isDir: true);

        for (var i = 0; i < entries.Length; i++)
        {
            // ISO9660 8.3 file identifiers add a `;1` version suffix.
            // cloud-init's nocloud reader copes with both
            // `user-data` and `user-data;1` shapes.
            var name = entries[i].Name + ";1";
            cursor += WriteDirectoryRecord(image, off + cursor, fileLbas[i],
                dataLen: fileSizes[i], name: name, isDir: false);
        }
    }

    /// <summary>Returns the number of bytes written.</summary>
    private static int WriteDirectoryRecord(
        byte[] image, int off, int lba, int dataLen, string name, bool isDir)
    {
        // Length = 33 + len(name) + (pad to even).
        var nameBytes = Encoding.ASCII.GetBytes(name);
        var len = 33 + nameBytes.Length;
        if ((len & 1) == 1) len++;   // pad odd-length identifier

        image[off + 0] = (byte)len;             // record length
        image[off + 1] = 0;                     // ext attr len
        WriteBothEndianU32(image, off + 2, lba);     // extent location
        WriteBothEndianU32(image, off + 10, dataLen);// data length
        // 18-24: recording date (7 bytes, all zero is acceptable)
        image[off + 25] = isDir ? (byte)0x02 : (byte)0x00;  // file flags
        image[off + 26] = 0;                    // file unit size (interleaved)
        image[off + 27] = 0;                    // interleave gap
        WriteBothEndianU16(image, off + 28, 1); // volume sequence number
        image[off + 32] = (byte)nameBytes.Length;
        Array.Copy(nameBytes, 0, image, off + 33, nameBytes.Length);
        // pad byte if the resulting record length is odd is already
        // covered by the `len` rounding above.
        return len;
    }

    // -- numeric helpers ------------------------------------------------

    private static void WriteUInt16LE(byte[] image, int off, ushort v)
    {
        image[off + 0] = (byte)(v & 0xFF);
        image[off + 1] = (byte)((v >> 8) & 0xFF);
    }
    private static void WriteUInt16BE(byte[] image, int off, ushort v)
    {
        image[off + 0] = (byte)((v >> 8) & 0xFF);
        image[off + 1] = (byte)(v & 0xFF);
    }
    private static void WriteUInt32LE(byte[] image, int off, uint v)
    {
        image[off + 0] = (byte)(v & 0xFF);
        image[off + 1] = (byte)((v >> 8) & 0xFF);
        image[off + 2] = (byte)((v >> 16) & 0xFF);
        image[off + 3] = (byte)((v >> 24) & 0xFF);
    }
    private static void WriteUInt32BE(byte[] image, int off, uint v)
    {
        image[off + 0] = (byte)((v >> 24) & 0xFF);
        image[off + 1] = (byte)((v >> 16) & 0xFF);
        image[off + 2] = (byte)((v >> 8) & 0xFF);
        image[off + 3] = (byte)(v & 0xFF);
    }
    private static void WriteBothEndianU16(byte[] image, int off, ushort v)
    {
        WriteUInt16LE(image, off, v);
        WriteUInt16BE(image, off + 2, v);
    }
    private static void WriteBothEndianU32(byte[] image, int off, int v)
        => WriteBothEndianU32(image, off, (uint)v);
    private static void WriteBothEndianU32(byte[] image, int off, uint v)
    {
        WriteUInt32LE(image, off, v);
        WriteUInt32BE(image, off + 4, v);
    }
    private static void WriteAscii(byte[] image, int off, string text, int length)
    {
        var bytes = Encoding.ASCII.GetBytes(text);
        var copy = Math.Min(bytes.Length, length);
        Array.Copy(bytes, 0, image, off, copy);
        for (var i = copy; i < length; i++)
        {
            image[off + i] = 0x20;  // pad with space (ECMA-119 a-character set)
        }
    }
}
