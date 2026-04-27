import threading

# Basic threading -- just existence and names
print(threading.current_thread().__class__.__name__)   # Thread or MainThread
print(threading.main_thread().__class__.__name__)

# Lock
lock = threading.Lock()
print(type(lock).__name__)                              # Lock or _RLock or thread.lock

lock.acquire()
lock.release()
print('lock ok')                                       # lock ok

# RLock
rlock = threading.RLock()
rlock.acquire()
rlock.acquire()
rlock.release()
rlock.release()
print('rlock ok')                                      # rlock ok

# Event
event = threading.Event()
print(event.is_set())                                  # False
event.set()
print(event.is_set())                                  # True
event.clear()
print(event.is_set())                                  # False

# Thread subclass
results = []
def worker(n):
    results.append(n * 2)

threads = [threading.Thread(target=worker, args=(i,)) for i in range(3)]
for t in threads:
    t.start()
for t in threads:
    t.join()
print(sorted(results))                                 # [0, 2, 4]

# Semaphore
sem = threading.Semaphore(2)
print(type(sem).__name__)                              # Semaphore or BoundedSemaphore

# Condition
cond = threading.Condition()
print(type(cond).__name__)                             # Condition

# active_count
print(threading.active_count() >= 1)                   # True

print('done')
