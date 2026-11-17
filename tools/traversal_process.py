"""Own only this worker's child. Closing a Windows job also handles worker crashes."""
import os


class ProcessScope:
    def __init__(self, owner_pid=None, own_worker=False):
        self.job = None
        self.owner = None
        self.contains_worker = False
        self.owner_pid = owner_pid
        if owner_pid is not None and owner_pid != os.getppid():
            raise RuntimeError("Traversal owner is not the process that launched this worker")
        if os.name != "nt":
            return
        import ctypes as c
        from ctypes import wintypes as w

        class IO(c.Structure):
            _fields_ = [(name, c.c_ulonglong) for name in
                        ("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]

        class Basic(c.Structure):
            _fields_ = [("process_time", c.c_longlong), ("job_time", c.c_longlong),
                        ("flags", w.DWORD), ("min_working", c.c_size_t), ("max_working", c.c_size_t),
                        ("active", w.DWORD), ("affinity", c.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]

        class Limits(c.Structure):
            _fields_ = [("basic", Basic), ("io", IO), ("process_memory", c.c_size_t),
                        ("job_memory", c.c_size_t), ("peak_process", c.c_size_t), ("peak_job", c.c_size_t)]

        self.api = c.WinDLL("kernel32", use_last_error=True)
        for name, args, result in [
            ("CreateJobObjectW", [w.LPVOID, w.LPCWSTR], w.HANDLE),
            ("SetInformationJobObject", [w.HANDLE, c.c_int, w.LPVOID, w.DWORD], w.BOOL),
            ("AssignProcessToJobObject", [w.HANDLE, w.HANDLE], w.BOOL),
            ("QueryInformationJobObject", [w.HANDLE, c.c_int, w.LPVOID, w.DWORD, w.LPVOID], w.BOOL),
            ("OpenProcess", [w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            ("WaitForSingleObject", [w.HANDLE, w.DWORD], w.DWORD),
            ("CloseHandle", [w.HANDLE], w.BOOL),
        ]:
            function = getattr(self.api, name)
            function.argtypes, function.restype = args, result
        self.job = self.api.CreateJobObjectW(None, None)
        limits = Limits()
        self._limits = limits
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.job or not self.api.SetInformationJobObject(self.job, 9, c.byref(limits), c.sizeof(limits)):
            self.close()
            raise c.WinError(c.get_last_error())
        if own_worker:
            # Children inherit this job at creation. A worker crash between
            # Popen and attach cannot strand a not-yet-assigned child.
            if not self.api.AssignProcessToJobObject(self.job, w.HANDLE(-1)):
                self.close()
                raise c.WinError(c.get_last_error())
            self.contains_worker = True
        if owner_pid is not None:
            # Hold a handle to the original owner, not a later process reusing its PID.
            self.owner = self.api.OpenProcess(0x100000, False, owner_pid)
            if not self.owner:
                self.close()
                raise RuntimeError("Traversal owner already exited")

    def attach(self, child):
        if self.contains_worker:
            return  # Already inherited at creation, with no breakaway flag.
        if self.job and not self.api.AssignProcessToJobObject(self.job, int(child._handle)):
            import ctypes
            raise ctypes.WinError(ctypes.get_last_error())

    def owner_exited(self):
        if self.owner:
            return self.api.WaitForSingleObject(self.owner, 0) == 0
        return self.owner_pid is not None and self.owner_pid != os.getppid()

    def active_processes(self):
        if not self.job:
            return None
        import ctypes as c

        class Accounting(c.Structure):
            _fields_ = [("times", c.c_longlong * 4), ("faults", c.c_ulong),
                        ("total", c.c_ulong), ("active", c.c_ulong), ("terminated", c.c_ulong)]

        value = Accounting()
        if not self.api.QueryInformationJobObject(self.job, 1, c.byref(value), c.sizeof(value), None):
            raise c.WinError(c.get_last_error())
        return value.active

    def close(self):
        if self.job and self.contains_worker:
            # Caller has waited/reaped the child. Do not kill the worker itself
            # on an ordinary close; abrupt worker death bypasses this disarm.
            import ctypes as c
            self._limits.basic.flags = 0
            if not self.api.SetInformationJobObject(self.job, 9, c.byref(self._limits), c.sizeof(self._limits)):
                raise c.WinError(c.get_last_error())
            self.contains_worker = False
        for attribute in ("job", "owner"):
            handle = getattr(self, attribute, None)
            if handle:
                self.api.CloseHandle(handle)
                setattr(self, attribute, None)
