# 1. Script is present and executable.
printf '\n== 1. inventory.sh is present and executable ==\n'
test -x ./inventory.sh && echo OK
# Expected: OK

# 2. Script runs and emits a header plus >= 6 inventory rows
#    (3 deployments/statefulsets + 3 services across the bookstore namespaces).
printf '\n== 2. inventory.sh emits header + >= 6 bookstore rows ==\n'
./inventory.sh | tee /tmp/zta-inventory.out
ROWS=$(tail -n +2 /tmp/zta-inventory.out | grep -cE 'bookstore-(frontend|api|data)')
echo "rows=$ROWS"
# Expected: rows=6   (or higher if you have added extra labelled resources)

# 3. Every inventoried row carries a non-empty data-class — Tenet 1's whole point.
printf '\n== 3. Every inventoried row has a recognised data-class ==\n'
awk 'NR>1 {print $4}' /tmp/zta-inventory.out | grep -cE '^(public|internal|confidential|restricted|secret)$'
# Expected: same number as rows above

