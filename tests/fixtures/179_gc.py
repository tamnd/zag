import gc

print(gc.isenabled())
gc.disable()
print(gc.isenabled())
gc.enable()
print(gc.isenabled())

# collect returns an int (actual count is nondeterministic)
n = gc.collect()
print(type(n).__name__)

# get_objects returns a list
print(isinstance(gc.get_objects(), list))

# callbacks is a list
print(isinstance(gc.callbacks, list))

# get_freeze_count
print(gc.get_freeze_count())
