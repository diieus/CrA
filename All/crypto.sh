#!/bin/bash

function  xor()
{
	local res=(`echo "$1" | sed "s/../0x& /g"`)
	shift 1
	while [[ "$1" ]]; do
		local one=(`echo "$1" | sed "s/../0x& /g"`)
		local count1=${#res[@]}
		if [ $count1 -lt ${#one[@]} ]
		then
			count1=${#one[@]}
		fi
		for (( i = 0; i < $count1; i++ ))
		do
			res[$i]=$((${one[$i]:-0} ^ ${res[$i]:-0}))
		done
		shift 1
	done
	printf "%02x" "${res[@]}"
}


#Init not made
INIT=0

init () {
	#Check for previous init
	if [ $INIT -eq 1 ]; then echo "Already initiated" && return 1;fi

	echo "Initialisation"
	echo "Step 1 : creating random XOR_KEYS"
	head -c 128 /dev/random | head -c 256 > VIP1mykey
	head -c 128 /dev/random | head -c 256 > VIP2mykey

	echo "Step 2 : creating random passwords"
	openssl rand -base64 8 > PW11
	openssl rand -base64 8 > PW21

	echo "Step 3 : encrypting the XOR_KEYS files"
	mkdir server server/1 server/2 DB
	openssl enc -aes-256-cbc -in VIP1mykey -out server/1/file11 -pass file:PW11
	openssl enc -aes-256-cbc -in VIP2mykey -out server/2/file21 -pass file:PW21
	rm VIP1mykey VIP2mykey

	echo "Step 4 : generating a shared password, encrypting the IDs and renaming the files"
	openssl rand -base64 8 > shared
	mv server/1/file11 server/1/$(echo $(echo "user_11" | openssl enc -e -aes-256-cbc -pass file:shared | xxd -p) | sed -e 's/[ ]//g')
	mv server/2/file21 server/2/$(echo $(echo "user_21" | openssl enc -e -aes-256-cbc -pass file:shared | xxd -p) | sed -e 's/[ ]//g')

	echo "Step 5 : creating the second keys, encrypt it and re-encrypt the XOR_KEYS files"
	openssl rand -base64 8 > TPW1
	openssl rand -base64 8 > TPW2

	openssl enc -aes-256-cbc -in TPW1 -out server/tfile11 -pass file:PW11
	openssl enc -aes-256-cbc -in TPW2 -out server/tfile21 -pass file:PW21

	tar -czf - server/1 | openssl enc -e -aes-256-cbc -out server/secured_1.tar.gz -pass file:TPW2
	tar -czf - server/2 | openssl enc -e -aes-256-cbc -out server/secured_2.tar.gz -pass file:TPW1

	rm -r server/1 server/2 TPW1 TPW2

	#Moving the passwords to simulate different entities
	mkdir 11 21
	mv PW11 11/PW11
	mv PW21 21/PW21
	cp shared 11/shared
	cp shared 21/shared
	rm shared

	#Init made
	INIT=1
}

start () {
	#Check for previous init
	if [ $INIT -eq 0 ]; then echo "Not initiated yet" && return 1;fi

	echo "Start"
	echo "Step 1 : decrypting the second keys"
	openssl enc -d -aes-256-cbc -in server/tfile11 -out TPW1 -pass file:11/PW11
	openssl enc -d -aes-256-cbc -in server/tfile21 -out TPW2 -pass file:21/PW21

	echo "Step 2 : first decrypting of the XOR_KEYS files"
	openssl enc -d -aes-256-cbc -in server/secured_1.tar.gz -pass file:TPW2 | tar xz
	openssl enc -d -aes-256-cbc -in server/secured_2.tar.gz -pass file:TPW1 | tar xz

	echo "Step 3 : second decrypting of the XOR_KEYS files"
	ls server/1 | while read line; do
		if [ "$(echo $line | xxd -r -p | openssl enc -d -aes-256-cbc -pass file:11/shared)" = "user_11" ]; then openssl enc -d -aes-256-cbc -in server/1/$line -out VIP1mykey -pass file:11/PW11; fi
	done
	ls server/2 | while read line; do
		if [ "$(echo $line | xxd -r -p | openssl enc -d -aes-256-cbc -pass file:21/shared)" = "user_21" ]; then openssl enc -d -aes-256-cbc -in server/2/$line -out VIP2mykey -pass file:21/PW21; fi
	done

	xor $(xxd -p VIP1mykey) $(xxd -p VIP2mykey) > theK

	echo "Started !"
}



add () {
	echo "Add"
	echo "Step 0: summoning start"
	start
	rm VIP1mykey VIP2mykey

	echo "Step 1 : get the data"
	read -p $'User, format : name.lastname (ex: john.doe)\n' user
	read -p $'Card number, format : xxxx-xxxx-xxxx-xxxx-yy-yy-zzz(z) (ex: 1234-4567-8901-2345-12-19-678)\n' bcnb

	echo "Step 2 : encrypt the data"
	#Format the data and add random salt
	echo -n $bcnb > TEMP
	sed -e s/-//g -i TEMP
	head -c 32 /dev/urandom | xxd -p | head -c 40 > REMOVEME
	if [ $(( $(stat --printf="%s" TEMP) % 2 )) -eq 1 ]
	then echo -n "F" >> REMOVEME
fi
cat TEMP >> REMOVEME
rm TEMP

#Encrypt the data
openssl enc -aes-256-cbc -in REMOVEME -out encrypted -pass file:theK
rm REMOVEME

echo "Step 3 : save the data"
echo $user:$(xxd -p encrypted) >> DB/secret

#Cleaning
rm -r server/1 server/2 theK TPW1 TPW2 encrypted
}

get () {
	echo "Get"
	echo "Step 0: summoning start"
	start
	rm VIP1mykey VIP2mykey

	echo "Step 1 : user name"
	read -p $'User, format : name.lastname (ex: john.doe)\n' user

	echo "Step 2 : search the data"
	#Format the data
	grep $user DB/secret > tempuser
	sed -e s/$user://g -i tempuser

	#For each bankcode, do
	cat tempuser | while read line; do
		echo -n $line > tmpline
		xxd -r -p tmpline > line

		#Decrypt the data
		openssl enc -d -aes-256-cbc -in line -out data -pass file:theK

		#Remove the salt, format the code and print it
		tail -c 24 data > code && sed -e s/F//g -i code
		cat code | awk '{ print substr( $0, 1, 4 ) "-" substr( $0, 5, 4 ) "-" substr( $0, 9, 4 ) "-" substr( $0, 13, 4 ), substr( $0, 17, 2 ) "/" substr( $0, 19, 2 ), substr( $0, 21, 4 ) }'


		#Cleaning
		rm code data
	done


	#Cleaning
	rm -r server/1 server/2 theK TPW1 TPW2 tmpline line tempuser
}

add_user (){
	echo "Add user"
	echo "Step 0: summoning start"
	start

	echo "Step 1 : user name (number) and 'job'"
	read -p $'User :\n' user

	job=0
	while [ $job -ne 1 ] && [ $job -ne 2 ]; do
		read -p $'Job (1 or 2) :\n' job
	done

	echo "Step 2 : creating the user"
	mkdir $job$user
	#Creating password
	openssl rand -base64 8 > $job$user'/PW'$job$user
	#Encrypting the XOR key with the password
	openssl enc -aes-256-cbc -in 'VIP'$job'mykey' -out file -pass file:$job$user'/PW'$job$user
	#Encrypting the name of the file
	mv file 'server/'$job/$(echo $(echo user_$user | openssl enc -e -aes-256-cbc -pass file:11/shared | xxd -p) | sed -e "s/[ ]//g")
	#Encrypting the directory
	tar -czf - server/$job | openssl enc -e -aes-256-cbc -out 'server/secured_'$job'.tar.gz' -pass file:TPW$(expr -1 \* $job + 3)
	#Encrypting the second key
	openssl enc -aes-256-cbc -in TPW1 -out server/tfile$job$user -pass file:$job$user/PW$job$user

	#Cleaning
	rm -r server/1 server/2 theK TPW1 TPW2 VIP1mykey VIP2mykey


}

remove_user (){
	echo "Remove user"
	echo "Step 0: summoning start"
	start

	echo "Step 1 : user name (number) and 'job'"
	read -p $'User :\n' user

	job=0
	while [ $job -ne 1 ] && [ $job -ne 2 ]; do
		read -p $'Job (1 or 2) :\n' job
	done

	echo "Step 2 : searching the user"
	ls server/$job | while read line; do
		if [ "$(echo $line | xxd -r -p | openssl enc -d -aes-256-cbc -pass file:11/shared)" = "user_$user" ]; then rm server/$job/$line && echo "First file removed !"; fi
	done
	tar -czf - server/$job | openssl enc -e -aes-256-cbc -out 'server/secured_'$job'.tar.gz' -pass file:TPW$(expr -1 \* $job + 3)

	rm server/tfile$job$user && echo "Second file removed !"

	rm -r $job$user && echo "The guy has been fired !"


	#Cleaning
	rm -r server/1 server/2 theK TPW1 TPW2 VIP1mykey VIP2mykey

}


#Not exited
EX=0

#Can't do "rm  !(*.sh)" without doing this before
shopt -s extglob

exit_all () {
	echo "Wish you a good day."
	#Exited
	EX=1


	#Cleaning
	rm -r !(crypto.sh)
}

#MAIN
#While not exited, do
while [ $EX -eq 0 ]; do
	#Execute the command if it is in the list
	read -p $'Command ? (init,add,get,exit_all,add_user,remove_user)\n' REP
	if [[ "$REP" =~ ^(init|add|get|exit_all|add_user|remove_user)$ ]]
	then $REP
else echo "Not in the list, retry"
fi
done
