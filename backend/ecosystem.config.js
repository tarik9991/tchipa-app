module.exports = {
  apps: [
    {
      name: 'tchipa-api',
      script: './server.js',
      cwd: '/var/www/tchipa-api',
      exec_mode: 'fork',
      kill_timeout: 3000,
      listen_timeout: 8000,
      restart_delay: 1000,
      env: {
        PORT: 3000,
        NODE_ENV: 'production'
      }
    }
  ]
};
