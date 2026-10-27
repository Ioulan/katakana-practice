# frozen_string_literal: true

module Color
  def self.green(s)  = "\e[32m#{s}\e[0m"
  def self.cyan(s)   = "\e[36m#{s}\e[0m"
  def self.yellow(s) = "\e[33m#{s}\e[0m"
  def self.bold(s)   = "\e[1m#{s}\e[0m"
  def self.dim(s)    = "\e[2m#{s}\e[0m"
end
