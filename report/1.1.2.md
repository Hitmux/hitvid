Modify the temporary directory creation logic: 
1. Try to use `/dev/shm` first to get the best performance. 
2. If the above method does not work, issue a warning and try to use `$HOME/tmp`. If it does not exist, try to create it. 
3. If neither of the above two methods is feasible, an error is reported. 

The rest of the code is unchanged.
