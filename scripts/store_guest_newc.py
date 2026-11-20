"""Write deterministic Linux newc CPIO from a trusted prepared guest tree.

No extraction, network fetch, tool installation, signing or extension execution.
This is not an admission lock generator. Review and pin the prepared guest and
toolchain independently before considering its output for package distribution.
"""
import argparse
import os
import pathlib
import stat

IMAGE_LIMIT = 512 * 1024 * 1024
RECORD_LIMIT = 100_000


class Archive:
    def __init__(self, destination):
        self.destination = destination
        self.total = 0

    def write(self, data):
        self.total += len(data)
        if self.total > IMAGE_LIMIT:
            raise ValueError('Store guest CPIO exceeds 512 MiB')
        self.destination.write(data)

    def align(self):
        self.write(b'\x00' * (-self.total % 4))

    def record(self, inode, name, mode, size, payload):
        fields = (inode, mode, 0, 0, 1, 0, size, 0, 0, 0, 0, len(name) + 1, 0)
        self.write(b'070701' + ''.join(f'{value:08x}' for value in fields).encode('ascii'))
        self.write(name + b'\x00')
        self.align()
        payload()
        self.align()


def _name(relative):
    encoded = relative.as_posix().encode('utf-8', errors='strict')
    if len(encoded) > 1024 or any(b < 32 or b == 127 or b == 92 for b in encoded):
        raise ValueError('ambiguous image path')
    return encoded


def _link_target(relative, target):
    if not target or '\\' in target or any(ord(c) < 32 or ord(c) == 127 for c in target):
        raise ValueError('ambiguous image symlink')
    # A signed Linux linker symlink may be absolute inside guest root. Check
    # for escapes lexically, without resolving it against the Mac filesystem.
    base = [] if target.startswith('/') else list(relative.parent.parts)
    for part in target.split('/'):
        if not part or part == '.':
            continue
        if part == '..':
            if not base:
                raise ValueError('image symlink escapes guest root')
            base.pop()
        else:
            base.append(part)
    value = target.encode('utf-8', errors='strict')
    if len(value) > 1024:
        raise ValueError('oversize image symlink')
    return value


def write_newc(root, destination):
    root = pathlib.Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('image root must be a real directory')
    entries = []
    for item in root.rglob('*'):
        if len(entries) >= RECORD_LIMIT:
            raise ValueError('too many image records')
        relative = item.relative_to(root)
        encoded = _name(relative)
        if encoded == b'TRAILER!!!':
            raise ValueError('reserved archive record')
        entries.append((encoded, relative, item))
    archive = Archive(destination)
    for inode, (name, relative, item) in enumerate(sorted(entries), start=1):
        info = item.lstat()
        if stat.S_ISDIR(info.st_mode):
            archive.record(inode, name, stat.S_IFDIR | 0o755, 0, lambda: None)
        elif stat.S_ISLNK(info.st_mode):
            value = _link_target(relative, os.readlink(item))
            archive.record(inode, name, stat.S_IFLNK | 0o777, len(value), lambda: archive.write(value))
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= IMAGE_LIMIT:
            with os.fdopen(os.open(item, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as file:
                read_info = os.fstat(file.fileno())
                if (read_info.st_ino, read_info.st_dev, read_info.st_size, read_info.st_mode) != (
                        info.st_ino, info.st_dev, info.st_size, info.st_mode):
                    raise ValueError('image file identity changed while opening')

                def stream():
                    remaining = info.st_size
                    while remaining:
                        data = file.read(min(remaining, 128 * 1024))
                        if not data:
                            raise ValueError('image file changed while reading')
                        archive.write(data)
                        remaining -= len(data)
                    if file.read(1):
                        raise ValueError('image file changed while reading')

                mode = stat.S_IFREG | (0o755 if info.st_mode & 0o111 else 0o644)
                archive.record(inode, name, mode, info.st_size, stream)
        else:
            raise ValueError(f'unsupported or unsafe image record: {name!r}')
    archive.record(0, b'TRAILER!!!', 0, 0, lambda: None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prepared_root', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    args = parser.parse_args()
    if args.output.resolve().is_relative_to(args.prepared_root.resolve()):
        parser.error('output must be outside the prepared guest tree')
    with args.output.open('xb') as destination:
        try:
            write_newc(args.prepared_root, destination)
        except BaseException:
            args.output.unlink()
            raise


if __name__ == '__main__':
    main()
