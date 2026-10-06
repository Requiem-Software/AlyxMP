using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace AlyxMP
{
    /// <summary>Reads single files out of a Valve VPK (v1 or v2, *_dir.vpk with or without numbered chunks).</summary>
    sealed class Vpk
    {
        struct Entry
        {
            public ushort Archive;
            public uint Offset, Length;
            public byte[] Preload;
        }

        readonly string dirPath;
        readonly long dataStart;
        readonly Dictionary<string, Entry> entries = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);

        public Vpk(string dirPath)
        {
            this.dirPath = dirPath;
            using (var r = new BinaryReader(File.OpenRead(dirPath)))
            {
                if (r.ReadUInt32() != 0x55AA1234) throw new InvalidDataException("not a VPK: " + dirPath);
                var version = r.ReadUInt32();
                var treeSize = r.ReadUInt32();
                int header = version == 2 ? 28 : 12;
                r.BaseStream.Position = header;
                var tree = r.ReadBytes((int)treeSize);
                dataStart = header + treeSize;
                Parse(tree);
            }
        }

        void Parse(byte[] tree)
        {
            int i = 0;
            string Str()
            {
                int j = Array.IndexOf(tree, (byte)0, i);
                var s = Encoding.UTF8.GetString(tree, i, j - i);
                i = j + 1;
                return s;
            }
            while (true)
            {
                var ext = Str();
                if (ext.Length == 0) break;
                while (true)
                {
                    var path = Str();
                    if (path.Length == 0) break;
                    while (true)
                    {
                        var name = Str();
                        if (name.Length == 0) break;
                        // crc u32, preload u16, archive u16, offset u32, length u32, terminator u16
                        var preloadLen = BitConverter.ToUInt16(tree, i + 4);
                        var e = new Entry
                        {
                            Archive = BitConverter.ToUInt16(tree, i + 6),
                            Offset = BitConverter.ToUInt32(tree, i + 8),
                            Length = BitConverter.ToUInt32(tree, i + 12),
                        };
                        i += 18;
                        e.Preload = new byte[preloadLen];
                        Array.Copy(tree, i, e.Preload, 0, preloadLen);
                        i += preloadLen;
                        var full = path.Trim().Length == 0 ? $"{name}.{ext}" : $"{path}/{name}.{ext}";
                        entries[full] = e;
                    }
                }
            }
        }

        public bool Contains(string name) => entries.ContainsKey(name);

        /// <summary>
        /// Write a single-file VPK v2 (the data inside the _dir file, like NoVR's). The game prefers files
        /// inside VPKs over loose ones, so overriding another mod's packed file takes a VPK of our own.
        /// </summary>
        public static void Write(string dirPath, IDictionary<string, byte[]> files)
        {
            var bytes = Build(files);
            // the game keeps the VPKs it mounted open; leave an identical one alone
            if (File.Exists(dirPath) && File.ReadAllBytes(dirPath).SequenceEqual(bytes)) return;
            File.WriteAllBytes(dirPath, bytes);
        }

        static byte[] Build(IDictionary<string, byte[]> files)
        {
            var tree = new MemoryStream();
            var data = new MemoryStream();
            var w = new BinaryWriter(tree);
            void Str(string s)
            {
                w.Write(Encoding.UTF8.GetBytes(s));
                w.Write((byte)0);
            }
            var list = files.Select(kv =>
            {
                var path = kv.Key.Replace('\\', '/');
                int slash = path.LastIndexOf('/');
                var dir = slash < 0 ? " " : path.Substring(0, slash);
                var file = slash < 0 ? path : path.Substring(slash + 1);
                int dot = file.LastIndexOf('.');
                return new
                {
                    Ext = dot < 0 ? " " : file.Substring(dot + 1),
                    Dir = dir,
                    Name = dot < 0 ? file : file.Substring(0, dot),
                    Bytes = kv.Value,
                };
            }).ToList();
            foreach (var ext in list.GroupBy(f => f.Ext))
            {
                Str(ext.Key);
                foreach (var dir in ext.GroupBy(f => f.Dir))
                {
                    Str(dir.Key);
                    foreach (var f in dir)
                    {
                        Str(f.Name);
                        w.Write(Crc32(f.Bytes));
                        w.Write((ushort)0);              // preload bytes
                        w.Write((ushort)0x7FFF);         // the data follows the tree, in this file
                        w.Write((uint)data.Position);
                        w.Write((uint)f.Bytes.Length);
                        w.Write((ushort)0xFFFF);
                        data.Write(f.Bytes, 0, f.Bytes.Length);
                    }
                    w.Write((byte)0);
                }
                w.Write((byte)0);
            }
            w.Write((byte)0);
            w.Flush();
            var treeBytes = tree.ToArray();
            var dataBytes = data.ToArray();

            var file = new MemoryStream();
            var fw = new BinaryWriter(file);
            fw.Write(0x55AA1234u);
            fw.Write(2u);
            fw.Write((uint)treeBytes.Length);
            fw.Write((uint)dataBytes.Length);
            fw.Write(0u);       // archive MD5 section
            fw.Write(48u);      // other MD5 section
            fw.Write(0u);       // signature section
            fw.Write(treeBytes);
            fw.Write(dataBytes);
            fw.Flush();
            using (var md5 = MD5.Create())
            {
                var treeSum = md5.ComputeHash(treeBytes);
                var archiveSum = md5.ComputeHash(new byte[0]);
                var wholeSum = md5.ComputeHash(file.ToArray());
                fw.Write(treeSum);
                fw.Write(archiveSum);
                fw.Write(wholeSum);
                fw.Flush();
            }
            return file.ToArray();
        }

        static uint[] crcTable;

        static uint Crc32(byte[] bytes)
        {
            if (crcTable == null)
            {
                var t = new uint[256];
                for (uint i = 0; i < 256; i++)
                {
                    uint c = i;
                    for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
                    t[i] = c;
                }
                crcTable = t;
            }
            uint crc = 0xFFFFFFFF;
            foreach (var b in bytes) crc = crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
            return ~crc;
        }

        public byte[] Read(string name)
        {
            if (!entries.TryGetValue(name, out var e)) return null;
            string file;
            long at;
            if (e.Archive == 0x7FFF)
            {
                file = dirPath;
                at = dataStart + e.Offset;
            }
            else
            {
                file = dirPath.Replace("_dir.vpk", $"_{e.Archive:000}.vpk");
                at = e.Offset;
            }
            var data = new byte[e.Preload.Length + e.Length];
            Array.Copy(e.Preload, data, e.Preload.Length);
            using (var f = File.OpenRead(file))
            {
                f.Position = at;
                int got = 0;
                while (got < e.Length)
                {
                    int n = f.Read(data, e.Preload.Length + got, (int)e.Length - got);
                    if (n <= 0) throw new EndOfStreamException(name);
                    got += n;
                }
            }
            return data;
        }
    }
}
