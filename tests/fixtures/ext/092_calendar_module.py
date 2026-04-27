# calendar module

import calendar

# isleap
print(calendar.isleap(2024))                       # True
print(calendar.isleap(2023))                       # False
print(calendar.isleap(2000))                       # True
print(calendar.isleap(1900))                       # False

# leapdays
print(calendar.leapdays(2000, 2024))               # 6

# weekday(year, month, day) - returns 0=Monday, 6=Sunday
print(calendar.weekday(2024, 1, 1))                # 0 (Monday)
print(calendar.weekday(2024, 1, 7))                # 6 (Sunday)

# monthrange
mr1 = calendar.monthrange(2024, 2)
print(int(mr1[0]), mr1[1])                        # 3 29 Thu=3, 29 days
mr2 = calendar.monthrange(2023, 2)
print(int(mr2[0]), mr2[1])                        # 2 28 Wed=2, 28 days

# month_name and month_abbr
print(calendar.month_name[1])                      # January
print(calendar.month_abbr[1])                      # Jan

# day_name and day_abbr
print(calendar.day_name[0])                        # Monday
print(calendar.day_abbr[6])                        # Sun

# Calendar class
c = calendar.Calendar(0)
weeks = c.monthdayscalendar(2024, 1)
print(len(weeks) >= 4)                             # True
print(weeks[0][0])                                 # 1 (first Monday is Jan 1, 2024)

# TextCalendar
tc = calendar.TextCalendar()
s = tc.formatmonth(2024, 1)
print(isinstance(s, str))                          # True
print('January' in s)                              # True

# HTMLCalendar
hc = calendar.HTMLCalendar()
h = hc.formatmonth(2024, 1)
print(isinstance(h, str))                          # True
print('<table' in h.lower() or 'table' in h.lower())  # True

# setfirstweekday
calendar.setfirstweekday(6)  # Sunday first
print(calendar.firstweekday())                     # 6
calendar.setfirstweekday(0)  # Reset to Monday

# timegm
import time
t = calendar.timegm((2024, 1, 1, 0, 0, 0, 0, 0, 0))
print(t)                                           # 1704067200

print('done')
