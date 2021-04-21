echo off
set company=%1
set broker=%2
sqlcmd -h -1 -W -i "C:\_filemask_query.sql" -s "|" -v Name00=%company% Name01=%broker% -o "_filemask.psv"
IF ERRORLEVEL 0 echo SqlCmd operations completed
IF ERRORLEVEL 1 echo SqlCmd operations not completed