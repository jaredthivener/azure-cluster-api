FROM node:18-alpine

# Install dependencies
WORKDIR /app
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

# Build the app
COPY . .
RUN yarn build

# Start the app
CMD ["yarn", "start"]
