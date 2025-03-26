FROM node:14

# Install dependencies
WORKDIR /app
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

# Build the app
COPY . .
RUN yarn build

# Start the app
CMD ["yarn", "start"]
