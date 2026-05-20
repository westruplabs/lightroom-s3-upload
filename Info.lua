return {
  LrSdkVersion        = 6.0,
  LrSdkMinimumVersion = 5.0,

  LrToolkitIdentifier = 'se.peterwestrup.s3upload',
  LrPluginName        = 'Upload to Amazon S3',

  LrExportServiceProvider = {
    title = 'Amazon S3',
    file  = 'ExportServiceProvider.lua',
  },

  VERSION = { major = 1, minor = 0, revision = 0 },
}
