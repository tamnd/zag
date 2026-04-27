# bisect module

import bisect

# bisect_left
lst = [1, 3, 5, 7, 9]
print(bisect.bisect_left(lst, 5))                 # 2
print(bisect.bisect_left(lst, 4))                 # 2
print(bisect.bisect_left(lst, 0))                 # 0
print(bisect.bisect_left(lst, 10))                # 5

# bisect_right (default bisect)
print(bisect.bisect_right(lst, 5))                # 3
print(bisect.bisect_right(lst, 4))                # 2
print(bisect.bisect(lst, 5))                      # 3 (same as bisect_right)

# insort_left
lst2 = [1, 3, 5, 7]
bisect.insort_left(lst2, 4)
print(lst2)                                       # [1, 3, 4, 5, 7]
bisect.insort_left(lst2, 3)
print(lst2)                                       # [1, 3, 3, 4, 5, 7]

# insort_right (default insort)
lst3 = [1, 3, 5, 7]
bisect.insort_right(lst3, 4)
print(lst3)                                       # [1, 3, 4, 5, 7]
bisect.insort(lst3, 3)
print(lst3)                                       # [1, 3, 3, 4, 5, 7]

# Using bisect for grade lookup
def grade(score):
    breakpoints = [60, 70, 80, 90]
    grades = 'FDCBA'
    return grades[bisect.bisect(breakpoints, score)]

grades = [grade(s) for s in [55, 65, 75, 85, 95]]
print(' '.join(grades))                           # F D C B A

# Count occurrences with bisect
def count_occurrences(lst, val):
    lo = bisect.bisect_left(lst, val)
    hi = bisect.bisect_right(lst, val)
    return hi - lo

sorted_lst = sorted([1, 3, 3, 5, 3, 7, 3])
print(count_occurrences(sorted_lst, 3))           # 4

print('done')
