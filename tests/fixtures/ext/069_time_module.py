# time module basics

import time

# time.time() returns a float (non-deterministic, just test type)
t = time.time()
print(isinstance(t, float))                         # True
print(t > 0)                                        # True

# time.sleep (just test it doesn't crash)
time.sleep(0)
print('sleep ok')                                   # sleep ok

# time.monotonic
m = time.monotonic()
print(isinstance(m, float))                         # True

# time.perf_counter
pc = time.perf_counter()
print(isinstance(pc, float))                        # True

# time.process_time
pt = time.process_time()
print(isinstance(pt, float))                        # True

# time.gmtime
gt = time.gmtime(0)
print(gt.tm_year)                                   # 1970
print(gt.tm_mon)                                    # 1
print(gt.tm_mday)                                   # 1
print(gt.tm_hour)                                   # 0
print(gt.tm_min)                                    # 0
print(gt.tm_sec)                                    # 0

# time.localtime (non-deterministic, just type check)
lt = time.localtime()
print(lt.tm_year > 2020)                           # True

# time.mktime
t2 = time.mktime(time.gmtime(0))
print(type(t2).__name__)                           # float

# time.strftime
ts = time.strftime('%Y', time.gmtime(0))
print(ts)                                          # 1970

# time.strptime
parsed = time.strptime('2024-01-15', '%Y-%m-%d')
print(parsed.tm_year)                              # 2024
print(parsed.tm_mon)                               # 1
print(parsed.tm_mday)                              # 15

# struct_time attributes
st = time.gmtime(3661)  # 1 hour, 1 minute, 1 second
print(st.tm_hour)                                  # 1
print(st.tm_min)                                   # 1
print(st.tm_sec)                                   # 1

print('done')
