`ps -eo pid,lstart,cmd --sort=-%mem | awk 'NR==1 {print; next} {cmd=substr($0, index($0,$7),50); print $1, $2, $3, $4, $5, $6, cmd}'
`
