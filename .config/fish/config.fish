if status --is-login

    # Commands to run ONLY on a physical console login
    echo "Welcome, local console user!"
    # Place your commands here
end

if status is-interactive

       	# Commands to run in interactive sessions can go here

	# Start the SSH agent
	eval (ssh-agent -c) > /dev/null

	# Add SSH keys
	ssh-add -q  ~/.ssh/station_id_ed25519

	#Display Pokemon
	#pokemon-colorscripts --no-title -r 1,3,6
	pokemon-colorscripts -r 1,2,3
	
	fish_add_path ~/Apps
end
