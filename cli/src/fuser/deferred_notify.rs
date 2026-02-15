use log::debug;
use std::{
    ffi::{OsStr, OsString},
    sync::mpsc,
};

/// A queued invalidation operation to be flushed by the notify thread.
#[derive(Debug)]
pub enum NotifyOp {
    InvalEntry { parent: u64, name: OsString },
    InvalInode { ino: u64, offset: i64, len: i64 },
}

/// Queues kernel cache invalidation requests for deferred execution.
///
/// FUSE notification writes to /dev/fuse cannot be issued from the session
/// loop thread — even outside callbacks — because the kernel processes
/// FUSE_NOTIFY_INVAL_ENTRY synchronously within the writev() call. That
/// processing can trigger d_invalidate → iput → FUSE_FORGET, which needs
/// the daemon to be reading /dev/fuse. Since the session loop thread is
/// blocked in writev(), it can't read, causing a deadlock.
///
/// DeferredNotifier solves this by sending operations over an mpsc channel
/// to a dedicated background thread that writes to /dev/fuse independently
/// of the session loop.
#[derive(Debug, Clone)]
pub struct DeferredNotifier {
    tx: mpsc::Sender<NotifyOp>,
}

impl DeferredNotifier {
    pub(crate) fn new(tx: mpsc::Sender<NotifyOp>) -> Self {
        Self { tx }
    }

    pub fn inval_entry(&self, parent: u64, name: &OsStr) {
        if let Err(e) = self.tx.send(NotifyOp::InvalEntry {
            parent,
            name: name.to_os_string(),
        }) {
            debug!("deferred inval_entry send failed (notify thread gone?): {e}");
        }
    }

    pub fn inval_inode(&self, ino: u64, offset: i64, len: i64) {
        if let Err(e) = self.tx.send(NotifyOp::InvalInode { ino, offset, len }) {
            debug!("deferred inval_inode send failed (notify thread gone?): {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{DeferredNotifier, NotifyOp};
    use std::ffi::OsStr;
    use std::sync::mpsc;

    #[test]
    fn queues_inval_inode() {
        let (tx, rx) = mpsc::channel();
        let deferred = DeferredNotifier::new(tx);

        deferred.inval_inode(42, 0, 0);

        let op = rx.recv().expect("expected queued notify op");
        match op {
            NotifyOp::InvalInode { ino, offset, len } => {
                assert_eq!(ino, 42);
                assert_eq!(offset, 0);
                assert_eq!(len, 0);
            }
            NotifyOp::InvalEntry { .. } => panic!("expected InvalInode op"),
        }
    }

    #[test]
    fn preserves_notification_order() {
        let (tx, rx) = mpsc::channel();
        let deferred = DeferredNotifier::new(tx);

        deferred.inval_entry(7, OsStr::new("foo"));
        deferred.inval_inode(7, 0, 0);

        let first = rx.recv().expect("expected first notify op");
        match first {
            NotifyOp::InvalEntry { parent, name } => {
                assert_eq!(parent, 7);
                assert_eq!(name, OsStr::new("foo"));
            }
            NotifyOp::InvalInode { .. } => panic!("expected InvalEntry first"),
        }

        let second = rx.recv().expect("expected second notify op");
        match second {
            NotifyOp::InvalInode { ino, offset, len } => {
                assert_eq!(ino, 7);
                assert_eq!(offset, 0);
                assert_eq!(len, 0);
            }
            NotifyOp::InvalEntry { .. } => panic!("expected InvalInode second"),
        }
    }
}
