import time

# Basic time functions
t = time.time()
print(type(t).__name__)                                # float
print(t > 0)                                           # True

# perf_counter
p1 = time.perf_counter()
time.sleep(0)
p2 = time.perf_counter()
print(p2 >= p1)                                        # True

# monotonic
m = time.monotonic()
print(type(m).__name__)                                # float

# gmtime / localtime
gmt = time.gmtime(0)
print(gmt.tm_year)                                     # 1970
print(gmt.tm_mon)                                      # 1
print(gmt.tm_mday)                                     # 1
print(gmt.tm_hour)                                     # 0
print(gmt.tm_min)                                      # 0
print(gmt.tm_sec)                                      # 0

# mktime
import time as t2
struct = t2.struct_time((2000, 1, 1, 0, 0, 0, 5, 1, 0))
ts = time.mktime(struct)
print(type(ts).__name__)                               # float

# strftime
s = time.strftime('%Y-%m-%d', time.gmtime(0))
print(s)                                               # 1970-01-01

# strptime
pt = time.strptime('2024-01-15', '%Y-%m-%d')
print(pt.tm_year)                                      # 2024
print(pt.tm_mon)                                       # 1
print(pt.tm_mday)                                      # 15

# time.time_ns
ns = time.time_ns()
print(type(ns).__name__)                               # int
print(ns > 0)                                          # True

# process_time
proc = time.process_time()
print(type(proc).__name__)                             # float

print('done')
