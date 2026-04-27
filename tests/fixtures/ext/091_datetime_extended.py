# datetime extended

from datetime import datetime, date, time, timedelta, timezone

# date operations
d1 = date(2024, 1, 15)
d2 = date(2024, 3, 20)
delta = d2 - d1
print(delta.days)                                  # 65

# date arithmetic
d3 = d1 + timedelta(days=30)
print(d3)                                          # 2024-02-14
print(d3.year, d3.month, d3.day)                  # 2024 2 14

# date properties
print(d1.weekday())                                # 0 (Monday)
print(d1.isoweekday())                             # 1 (Monday = 1 in ISO)
ic = d1.isocalendar()
print((ic.year, ic.week))                          # (2024, 3) year and week

# date formatting
print(d1.strftime('%Y-%m-%d'))                    # 2024-01-15
print(d1.strftime('%d/%m/%Y'))                    # 15/01/2024

# date parsing
d4 = datetime.strptime('2024-06-15', '%Y-%m-%d').date()
print(d4)                                          # 2024-06-15

# time
t1 = time(14, 30, 0)
print(t1)                                          # 14:30:00
print(t1.hour, t1.minute, t1.second)              # 14 30 0

# datetime
dt1 = datetime(2024, 1, 15, 14, 30, 0)
print(dt1)                                         # 2024-01-15 14:30:00
print(dt1.date())                                  # 2024-01-15
print(dt1.time())                                  # 14:30:00

# datetime arithmetic
dt2 = dt1 + timedelta(hours=2, minutes=30)
print(dt2)                                         # 2024-01-15 17:00:00

# timedelta operations
td1 = timedelta(days=1, hours=2, minutes=30)
td2 = timedelta(days=0, hours=3)
print(td1 + td2)                                   # 1 day, 5:30:00
print(td1 - td2)                                   # 23:30:00

# timezone
utc = timezone.utc
dt3 = datetime(2024, 1, 15, 12, 0, 0, tzinfo=utc)
print(dt3.tzinfo)                                  # UTC

# isoformat
dt4 = datetime(2024, 1, 15, 14, 30, 45)
print(dt4.isoformat())                             # 2024-01-15T14:30:45

# fromisoformat
dt5 = datetime.fromisoformat('2024-01-15T14:30:45')
print(dt5.year, dt5.month, dt5.day)               # 2024 1 15
print(dt5.hour, dt5.minute, dt5.second)           # 14 30 45

print('done')
