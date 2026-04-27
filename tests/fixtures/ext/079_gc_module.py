# gc module

import gc

# gc.collect
collected = gc.collect()
print(isinstance(collected, int))                  # True
print(collected >= 0)                              # True

# gc.isenabled / gc.enable / gc.disable
print(gc.isenabled())                              # True
gc.disable()
print(gc.isenabled())                              # False
gc.enable()
print(gc.isenabled())                              # True

# gc.get_count
count = gc.get_count()
print(isinstance(count, tuple))                    # True
print(len(count))                                  # 3

# gc.get_threshold
threshold = gc.get_threshold()
print(isinstance(threshold, tuple))                # True
print(len(threshold))                              # 3

# gc.set_threshold and get
gc.set_threshold(500, 8, 3)
t = gc.get_threshold()
print(t[0])                                        # 500
print(t[1])                                        # 8
print(t[2])                                        # 3

# gc.get_objects
objs = gc.get_objects()
print(isinstance(objs, list))                      # True

# Cycle detection (best-effort)
class Node:
    def __init__(self):
        self.ref = None

a = Node()
b = Node()
a.ref = b
b.ref = a  # cycle

del a
del b
after = gc.collect()
print(after >= 0)                                  # True

# gc.callbacks
def my_cb(phase, info):
    pass

gc.callbacks.append(my_cb)
gc.collect()
gc.callbacks.remove(my_cb)
print('callbacks ok')                              # callbacks ok

# gc.is_tracked (may return True or False depending on impl)
lst = [1, 2, 3]
result = gc.is_tracked(lst)
print(isinstance(result, bool))                    # True

print('done')
