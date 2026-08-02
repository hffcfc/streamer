# Use an official base image that has bash installed
FROM ubuntu:24.04

# Set the working directory inside the container
WORKDIR /app

# Copy the local script into the container's working directory
COPY run.sh .

# Ensure the script has executable permissions
RUN chmod +x run.sh

# Execute the script using bash when the container starts
CMD ["bash", "run.sh"]
